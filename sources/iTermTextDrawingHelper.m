//
//  iTermTextDrawingHelper.m
//  iTerm2
//
//  Created by George Nachman on 3/9/15.
//
//

#import "iTermTextDrawingHelper.h"

#import "CharacterRun.h"
#import "CharacterRunInline.h"
#import "charmaps.h"
#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermBackgroundColorRun.h"
#import "iTermColorMap.h"
#import "iTermController.h"
#import "iTermFindCursorView.h"
#import "iTermIndicatorsHelper.h"
#import "iTermSelection.h"
#import "iTermTextExtractor.h"
#import "MovingAverage.h"
#import "NSColor+iTerm.h"
#import "VT100ScreenMark.h"
#import "VT100Terminal.h"  // TODO: Remove this dependency

static const int kBadgeMargin = 4;
static const int kBadgeRightMargin = 10;

static void iTermMakeBackgroundColorRun(iTermBackgroundColorRun *run,
                                        screen_char_t *theLine,
                                        VT100GridCoord coord,
                                        iTermTextExtractor *extractor,
                                        NSIndexSet *selectedIndexes,
                                        NSData *matches,
                                        int width) {
    if (theLine[coord.x].code == DWC_SKIP && !theLine[coord.x].complexChar) {
        run->selected = NO;
    } else {
        run->selected = [selectedIndexes containsIndex:coord.x];
    }
    if (matches) {
        // Test if this char is a highlighted match from a Find.
        const int theIndex = coord.x / 8;
        const int bitMask = 1 << (coord.x & 7);
        const char *matchBytes = (const char *)matches.bytes;
        run->isMatch = theIndex < [matches length] && (matchBytes[theIndex] & bitMask);
    } else {
        run->isMatch = NO;
    }
    run->bgColor = theLine[coord.x].backgroundColor;
    run->bgGreen = theLine[coord.x].bgGreen;
    run->bgBlue = theLine[coord.x].bgBlue;
    run->bgColorMode = theLine[coord.x].backgroundColorMode;
}


@implementation iTermTextDrawingHelper {
    // Current font. Only valid for the duration of a single drawing context.
    NSFont *_selectedFont;

    // Graphics for marks.
    NSImage *_markImage;
    NSImage *_markErrImage;

    // Last position of blinking cursor
    VT100GridCoord _oldCursorPosition;

    // Used by drawCursor: to remember the last time the cursor moved to avoid drawing a blinked-out
    // cursor while it's moving.
    NSTimeInterval _lastTimeCursorMoved;

    BOOL _blinkingFound;

    MovingAverage *_drawRectDuration;
    MovingAverage *_drawRectInterval;

    // Frame of the view we're drawing into.
    NSRect _frame;

    // The -visibleRect of the view we're drawing into.
    NSRect _visibleRect;
    
    NSSize _scrollViewContentSize;
    NSRect _scrollViewDocumentVisibleRect;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _markImage = [[NSImage imageNamed:@"mark"] retain];
        _markErrImage = [[NSImage imageNamed:@"mark_err"] retain];
        if ([iTermAdvancedSettingsModel logDrawingPerformance]) {
            NSLog(@"** Drawing performance timing enabled **");
            _drawRectDuration = [[MovingAverage alloc] init];
            _drawRectInterval = [[MovingAverage alloc] init];
        }
    }
    return self;
}

- (void)dealloc {
    [_selection release];
    [_cursorGuideColor release];
    [_badgeImage release];
    [_unfocusedSelectionColor release];
    [_markedText release];
    [_colorMap release];

    [_selectedFont release];
    [_markImage release];
    [_markErrImage release];
    [_drawRectDuration release];
    [_drawRectInterval release];

    [super dealloc];
}

#pragma mark - Drawing: General

- (void)drawTextViewContentInRect:(NSRect)rect
                         rectsPtr:(const NSRect *)rectArray
                        rectCount:(NSInteger)rectCount {
    DLog(@"drawRect:%@ in view %@", [NSValue valueWithRect:rect], _delegate);
    [self updateCachedMetrics];

    // If there are two or more rects that need display, the OS will pass in |rect| as the smallest
    // bounding rect that contains them all. Luckily, we can get the list of the "real" dirty rects
    // and they're guaranteed to be disjoint. So draw each of them individually.
    if (_drawRectDuration) {
        [self startTiming];
    }

    for (int i = 0; i < rectCount; i++) {
        DLog(@"drawRect - draw sub rectangle %@", [NSValue valueWithRect:rectArray[i]]);
        [self clipAndDrawRect:rectArray[i]];
    }

    if (_drawRectDuration) {
        [self stopTiming];
    }
}

- (void)clipAndDrawRect:(NSRect)rect {
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];

    // Compute the coordinate range.
    VT100GridCoordRange coordRange = [self coordRangeForRect:rect];

    // Clip to the area that needs to be drawn. We re-create the rect from the coord range to ensure
    // it falls on the boundary of the cells.
    NSRect innerRect = [self rectForCoordRange:coordRange];
    NSRectClip(innerRect);

    // Draw an extra ring of characters outside it.
    NSRect outerRect = [self rectByGrowingRectByOneCell:innerRect];
    [self drawOneRect:outerRect];

    [context restoreGraphicsState];
}

- (void)drawOneRect:(NSRect)rect {
    // The range of chars in the line that need to be drawn.
    VT100GridCoordRange coordRange = [self drawableCoordRangeForRect:rect];

    double curLineWidth = _gridSize.width * _cellSize.width;
    if (_cellSize.height <= 0 || curLineWidth <= 0) {
        DLog(@"height or width too small");
        return;
    }

    // Configure graphics
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeCopy];

    iTermTextExtractor *extractor = [self.delegate drawingHelperTextExtractor];
    int overflow = _scrollbackOverflow;
    _blinkingFound = NO;

    // We work hard to paint all the backgrounds first and then all the foregrounds. The reason this
    // is necessary is because sometimes a glyph is larger than its cell. Some fonts draw narrow-
    // width characters as full-width, some combining marks (e.g., combining enclosing circle) are
    // necessarily larger than a cell, etc. For example, see issue 3446.
    //
    // By drawing characters after backgrounds and also drawing an extra "ring" of characters just
    // outside the clipping region, we allow oversize characters to draw outside their bounds
    // without getting painted-over by a background color. Of course if a glyph extends more than
    // one full cell outside its bounds, it will still get overwritten by a background sometimes.

    // First, find all the background runs. The outer array (backgroundRunArrays) will have one
    // element per line. That element (a PTYTextViewBackgroundRunArray) contains the line number,
    // y origin, and an array of PTYTextViewBackgroundRunBox objects.
    NSRange charRange = NSMakeRange(coordRange.start.x, coordRange.end.x - coordRange.start.x);
    double y = coordRange.start.y * _cellSize.height;
    // An array of PTYTextViewBackgroundRunArray objects (one element per line).
    NSMutableArray *backgroundRunArrays = [NSMutableArray array];
    for (int line = coordRange.start.y; line < coordRange.end.y; line++, y += _cellSize.height) {
        if (line >= overflow) {
            // If overflow > 0 then the lines in the dataSource are not
            // lined up in the normal way with the view. This happens when
            // the dataSource has scrolled its contents up but -[refresh]
            // has not been called yet, so the view's contents haven't been
            // scrolled up yet. When that's the case, the first line of the
            // view is what the first line of the dataSource was before
            // it overflowed. Continue to draw text in this out-of-alignment
            // manner until refresh is called and gets things in sync again.
            int n = line - overflow;
            [self drawMarginsAndMarkForLine:n y:y];

            NSData *matches = [_delegate drawingHelperMatchesOnLine:n];
            NSArray *backgroundRuns = [self backgroundRunsInLine:n
                                                     withinRange:charRange
                                                         matches:matches
                                                        anyBlink:&_blinkingFound
                                                   textExtractor:extractor];
            iTermBackgroundColorRunsInLine *runArray =
                [[[iTermBackgroundColorRunsInLine alloc] init] autorelease];
            runArray.array = backgroundRuns;
            runArray.y = y;
            runArray.line = n;
            [backgroundRunArrays addObject:runArray];
        }
    }

    // Now iterate over the lines and paint the backgrounds.
    for (iTermBackgroundColorRunsInLine *runArray in backgroundRunArrays) {
        [self drawBackgroundForLine:runArray.line
                                atY:runArray.y
                               runs:runArray.array];
        [self drawMarginsAndMarkForLine:runArray.line y:runArray.y];
    }

    // Draw other background-like stuff that goes behind text.
    [self drawAccessoriesInRect:rect coordRange:coordRange];

    // Now iterate over the lines and paint the characters.
    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    for (iTermBackgroundColorRunsInLine *runArray in backgroundRunArrays) {
        [self drawCharactersForLine:runArray.line
                                atY:runArray.y
                     backgroundRuns:runArray.array
                            context:ctx];
        [self drawNoteRangesOnLine:runArray.line];
    }

    [self drawExcessAtLine:coordRange.end.y];
    [self drawTopMargin];

    // If the IME is in use, draw its contents over top of the "real" screen
    // contents.
    [self drawInputMethodEditorTextAt:_cursorCoord.x
                                    y:_cursorCoord.y
                                width:_gridSize.width
                               height:_gridSize.height
                         cursorHeight:self.cursorHeight
                                  ctx:ctx];
    [self drawCursor];
    _blinkingFound |= self.cursorBlinking;
    
    [_selectedFont release];
    _selectedFont = nil;
}

#pragma mark - Drawing: Background

- (void)drawBackgroundForLine:(int)line
                          atY:(CGFloat)yOrigin
                         runs:(NSArray *)runs {
    for (iTermBoxedBackgroundColorRun *box in runs) {
        iTermBackgroundColorRun *run = box.valuePointer;
        NSRect rect = NSMakeRect(floor(MARGIN + run->range.location * _cellSize.width),
                                 yOrigin,
                                 ceil(run->range.length * _cellSize.width),
                                 _cellSize.height);

        if (_hasBackgroundImage) {
            [self.delegate drawingHelperDrawBackgroundImageInRect:rect
                                           blendDefaultBackground:NO];
        }

        NSColor *color = [self colorForBackgroundRun:run];
        [color set];
        NSRectFillUsingOperation(rect,
                                 _hasBackgroundImage ? NSCompositeSourceOver : NSCompositeCopy);
        box.backgroundColor = color;
    }
}

- (NSColor *)colorForBackgroundRun:(iTermBackgroundColorRun *)run {
    NSColor *color;
    if (run->isMatch && !run->selected) {
        color = [NSColor colorWithCalibratedRed:1 green:1 blue:0 alpha:1];
    } else if (run->selected) {
        color = [self selectionColorForCurrentFocus];
    } else {
        if (_reverseVideo &&
            run->bgColor == ALTSEM_DEFAULT &&
            run->bgColorMode == ColorModeAlternate) {
            // Reverse video is only applied to default background-
            // color chars.
            color = [_delegate drawingHelperColorForCode:ALTSEM_DEFAULT
                                                   green:0
                                                    blue:0
                                               colorMode:ColorModeAlternate
                                                    bold:NO
                                                   faint:NO
                                            isBackground:NO];
        } else {
            // Use the regular background color.
            color = [_delegate drawingHelperColorForCode:run->bgColor
                                                   green:run->bgGreen
                                                    blue:run->bgBlue
                                               colorMode:run->bgColorMode
                                                    bold:NO
                                                   faint:NO
                                            isBackground:YES];
        }
    }
    color = [color colorWithAlphaComponent:_transparencyAlpha];
    return color;
}

- (void)drawExcessAtLine:(int)line {
    NSRect excessRect;
    if (_numberOfIMELines) {
        // Draw a default-color rectangle from below the last line of text to
        // the bottom of the frame to make sure that IME offset lines are
        // cleared when the screen is scrolled up.
        excessRect.origin.x = 0;
        excessRect.origin.y = line * _cellSize.height;
        excessRect.size.width = _scrollViewContentSize.width;
        excessRect.size.height = _frame.size.height - excessRect.origin.y;
    } else  {
        // Draw the excess bar at the bottom of the visible rect the in case
        // that some other tab has a larger font and these lines don't fit
        // evenly in the available space.
        NSRect visibleRect = _visibleRect;
        excessRect.origin.x = 0;
        excessRect.origin.y = visibleRect.origin.y + visibleRect.size.height - _excess;
        excessRect.size.width = _scrollViewContentSize.width;
        excessRect.size.height = _excess;
    }

    [self.delegate drawingHelperDrawBackgroundImageInRect:excessRect
                                   blendDefaultBackground:YES];
}

- (void)drawTopMargin {
    // Draw a margin at the top of the visible area.
    NSRect topMarginRect = _visibleRect;
    if (topMarginRect.origin.y > 0) {
        topMarginRect.size.height = VMARGIN;
        [self.delegate drawingHelperDrawBackgroundImageInRect:topMarginRect
                                       blendDefaultBackground:YES];
    }
}

- (NSRect)drawMarginsAtY:(double)curY widthInChars:(int)width {
    NSRect leftMargin = NSMakeRect(0, curY, MARGIN, _cellSize.height);
    NSRect rightMargin;
    NSRect visibleRect = _visibleRect;
    rightMargin.origin.x = _cellSize.width * width + MARGIN;
    rightMargin.origin.y = curY;
    rightMargin.size.width = visibleRect.size.width - rightMargin.origin.x;
    rightMargin.size.height = _cellSize.height;

    // Draw background in margins
    [self.delegate drawingHelperDrawBackgroundImageInRect:leftMargin
                                   blendDefaultBackground:YES];
    [self.delegate drawingHelperDrawBackgroundImageInRect:rightMargin
                                   blendDefaultBackground:YES];
    return leftMargin;
}

- (void)drawMarginsAndMarkForLine:(int)line y:(CGFloat)y {
    NSRect leftMargin = [self drawMarginsAtY:y
                                widthInChars:_gridSize.width];
    [self drawMarkIfNeededOnLine:line leftMarginRect:leftMargin];
}

- (void)drawStripesInRect:(NSRect)rect {
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];

    const CGFloat kStripeWidth = 40;
    const double kSlope = 1;

    for (CGFloat x = kSlope * -fmod(rect.origin.y, kStripeWidth * 2) -2 * kStripeWidth ;
         x < rect.origin.x + rect.size.width;
         x += kStripeWidth * 2) {
        if (x + 2 * kStripeWidth + rect.size.height * kSlope < rect.origin.x) {
            continue;
        }
        NSBezierPath* thePath = [NSBezierPath bezierPath];

        [thePath moveToPoint:NSMakePoint(x, rect.origin.y + rect.size.height)];
        [thePath lineToPoint:NSMakePoint(x + kSlope * rect.size.height, rect.origin.y)];
        [thePath lineToPoint:NSMakePoint(x + kSlope * rect.size.height + kStripeWidth, rect.origin.y)];
        [thePath lineToPoint:NSMakePoint(x + kStripeWidth, rect.origin.y + rect.size.height)];
        [thePath closePath];

        [[[NSColor redColor] colorWithAlphaComponent:0.15] set];
        [thePath fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - Drawing: Accessories

- (void)drawAccessoriesInRect:(NSRect)bgRect coordRange:(VT100GridCoordRange)coordRange {
    [self drawBadgeInRect:bgRect];

    // Draw red stripes in the background if sending input to all sessions
    if (_showStripes) {
        [self drawStripesInRect:bgRect];
    }

    // Highlight cursor line if the cursor is on this line and it's on.
    int cursorLine = _cursorCoord.y + _numberOfScrollbackLines;
    const BOOL drawCursorGuide = (self.highlightCursorLine &&
                                  cursorLine >= coordRange.start.y &&
                                  cursorLine < coordRange.end.y);
    if (drawCursorGuide) {
        CGFloat y = (cursorLine - _scrollbackOverflow) * _cellSize.height;
        [self drawCursorGuideForColumns:NSMakeRange(coordRange.start.x,
                                                    coordRange.end.x - coordRange.start.x)
                                      y:y];
    }
}

- (void)drawCursorGuideForColumns:(NSRange)range y:(CGFloat)yOrigin {
    [_cursorGuideColor set];
    NSPoint textOrigin = NSMakePoint(MARGIN + range.location * _cellSize.width, yOrigin);
    NSRect rect = NSMakeRect(textOrigin.x,
                             textOrigin.y,
                             range.length * _cellSize.width,
                             _cellSize.height);
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);

    rect.size.height = 1;
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);

    rect.origin.y += _cellSize.height - 1;
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);
}

- (void)drawMarkIfNeededOnLine:(int)line leftMarginRect:(NSRect)leftMargin {
    VT100ScreenMark *mark = [self.delegate drawingHelperMarkOnLine:line];
    if (mark.isVisible) {
        NSImage *image = mark.code ? _markErrImage : _markImage;
        CGFloat offset = (_cellSize.height - _markImage.size.height) / 2.0;
        [image drawAtPoint:NSMakePoint(leftMargin.origin.x,
                                       leftMargin.origin.y + offset)
                  fromRect:NSMakeRect(0, 0, _markImage.size.width, _markImage.size.height)
                 operation:NSCompositeSourceOver
                  fraction:1.0];
    }
}

- (void)drawNoteRangesOnLine:(int)line {
    NSArray *noteRanges = [self.delegate drawingHelperCharactersWithNotesOnLine:line];
    if (noteRanges.count) {
        for (NSValue *value in noteRanges) {
            VT100GridRange range = [value gridRangeValue];
            CGFloat x = range.location * _cellSize.width + MARGIN;
            CGFloat y = line * _cellSize.height;
            [[NSColor yellowColor] set];

            CGFloat maxX = MIN(_frame.size.width - MARGIN, range.length * _cellSize.width + x);
            CGFloat w = maxX - x;
            NSRectFill(NSMakeRect(x, y + _cellSize.height - 1.5, w, 1));
            [[NSColor orangeColor] set];
            NSRectFill(NSMakeRect(x, y + _cellSize.height - 1, w, 1));
        }

    }
}

- (void)drawTimestamps {
    [self updateCachedMetrics];

    for (int y = _scrollViewDocumentVisibleRect.origin.y / _cellSize.height;
         y < NSMaxY(_scrollViewDocumentVisibleRect) / _cellSize.height && y < _numberOfLines;
         y++) {
        [self drawTimestampForLine:y];
    }
}

- (void)drawTimestampForLine:(int)line {
    NSDate *timestamp = [_delegate drawingHelperTimestampForLine:line];
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    const NSTimeInterval day = -86400;
    const NSTimeInterval timeDelta = [timestamp timeIntervalSinceNow];
    if (timeDelta < day * 365) {
        // More than a year ago: include year
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"yyyyMMMd hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    } else if (timeDelta < day * 7) {
        // 1 week to 1 year ago: include date without year
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"MMMd hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    } else if (timeDelta < day) {
        // 1 day to 1 week ago: include day of week
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"EEE hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];

    } else {
        // In last 24 hours, just show time
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    }

    NSString *s = [fmt stringFromDate:timestamp];
    if (!timestamp || ![timestamp timeIntervalSinceReferenceDate]) {
        s = @"";
    }

    NSSize size = [s sizeWithAttributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:10] }];
    int w = size.width + MARGIN;
    int x = MAX(0, _frame.size.width - w);
    CGFloat y = line * _cellSize.height;
    NSColor *bgColor = [_colorMap colorForKey:kColorMapBackground];
    NSColor *fgColor = [_colorMap mutedColorForKey:kColorMapForeground];
    NSColor *shadowColor;
    if ([fgColor isDark]) {
        shadowColor = [NSColor whiteColor];
    } else {
        shadowColor = [NSColor blackColor];
    }

    const CGFloat alpha = 0.75;
    NSGradient *gradient =
    [[[NSGradient alloc] initWithStartingColor:[bgColor colorWithAlphaComponent:0]
                                   endingColor:[bgColor colorWithAlphaComponent:alpha]] autorelease];
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
    [gradient drawInRect:NSMakeRect(x - 20, y, 20, _cellSize.height) angle:0];

    [[bgColor colorWithAlphaComponent:alpha] set];
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
    NSRectFillUsingOperation(NSMakeRect(x, y, w, _cellSize.height), NSCompositeSourceOver);

    NSShadow *shadow = [[[NSShadow alloc] init] autorelease];
    shadow.shadowColor = shadowColor;
    shadow.shadowBlurRadius = 0.2f;
    shadow.shadowOffset = CGSizeMake(0.5, -0.5);

    NSDictionary *attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:10],
                                  NSForegroundColorAttributeName: fgColor,
                                  NSShadowAttributeName: shadow };
    CGFloat offset = (_cellSize.height - size.height) / 2;
    [s drawAtPoint:NSMakePoint(x, y + offset) withAttributes:attributes];
}

- (NSSize)drawBadgeInRect:(NSRect)rect {
    NSImage *image = _badgeImage;
    if (!image) {
        return NSZeroSize;
    }
    NSSize textViewSize = _frame.size;
    NSSize visibleSize = _scrollViewDocumentVisibleRect.size;
    NSSize imageSize = image.size;
    NSRect destination = NSMakeRect(textViewSize.width - imageSize.width - kBadgeRightMargin,
                                    textViewSize.height - visibleSize.height + kiTermIndicatorStandardHeight,
                                    imageSize.width,
                                    imageSize.height);
    NSRect intersection = NSIntersectionRect(rect, destination);
    if (intersection.size.width == 0 || intersection.size.height == 1) {
        return NSZeroSize;
    }
    NSRect source = intersection;
    source.origin.x -= destination.origin.x;
    source.origin.y -= destination.origin.y;
    source.origin.y = imageSize.height - (source.origin.y + source.size.height);

    [image drawInRect:intersection
             fromRect:source
            operation:NSCompositeSourceOver
             fraction:1
       respectFlipped:YES
                hints:nil];
    imageSize.width += kBadgeMargin + kBadgeRightMargin;
    return imageSize;
}

#pragma mark - Drawing: Text

- (void)drawCharactersForLine:(int)line
                          atY:(CGFloat)y
               backgroundRuns:(NSArray *)backgroundRuns
                      context:(CGContextRef)ctx {
    screen_char_t* theLine = [self.delegate drawingHelperLineAtIndex:line];
    NSData *matches = [_delegate drawingHelperMatchesOnLine:line];
    for (iTermBoxedBackgroundColorRun *box in backgroundRuns) {
        iTermBackgroundColorRun *run = box.valuePointer;
        NSPoint textOrigin = NSMakePoint(MARGIN + run->range.location * _cellSize.width, y);

        [self constructAndDrawRunsForLine:theLine
                                      row:line
                                  inRange:run->range
                          startingAtPoint:textOrigin
                               bgselected:run->selected
                                  bgColor:box.backgroundColor
                                  matches:matches
                                  context:ctx];
    }
}

- (void)constructAndDrawRunsForLine:(screen_char_t *)theLine
                                row:(int)row
                            inRange:(NSRange)indexRange
                    startingAtPoint:(NSPoint)initialPoint
                         bgselected:(BOOL)bgselected
                            bgColor:(NSColor*)bgColor
                            matches:(NSData*)matches
                            context:(CGContextRef)ctx {
    const int width = _gridSize.width;
    CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:width];
    CRun *run = [self constructTextRuns:initialPoint
                                   line:theLine
                                    row:row
                               selected:bgselected
                             indexRange:indexRange
                        backgroundColor:bgColor
                                matches:matches
                                storage:storage];

    if (run) {
        [self drawRunsAt:initialPoint run:run storage:storage context:ctx];
        CRunFree(run);
    }
}

- (void)drawRunsAt:(NSPoint)initialPoint
               run:(CRun *)run
           storage:(CRunStorage *)storage
           context:(CGContextRef)ctx {
    CGContextSetTextDrawingMode(ctx, kCGTextFill);
    while (run) {
        [self drawRun:run ctx:ctx initialPoint:initialPoint storage:storage];
        run = run->next;
    }
}

- (void)drawRun:(CRun *)currentRun
            ctx:(CGContextRef)ctx
   initialPoint:(NSPoint)initialPoint
        storage:(CRunStorage *)storage {
    NSPoint startPoint = NSMakePoint(initialPoint.x + currentRun->x, initialPoint.y);
    CGContextSetShouldAntialias(ctx, currentRun->attrs.antiAlias);

    // If there is an underline, save some values before the run gets chopped up.
    CGFloat runWidth = 0;
    int length = currentRun->string ? 1 : currentRun->length;
    NSSize *advances = nil;
    if (currentRun->attrs.underline) {
        advances = CRunGetAdvances(currentRun);
        for (int i = 0; i < length; i++) {
            runWidth += advances[i].width;
        }
    }

    if (!currentRun->string) {
        // Non-complex, except for glyphs we can't find.
        while (currentRun->length) {
            int firstComplexGlyph = [self drawSimpleRun:currentRun
                                                    ctx:ctx
                                           initialPoint:initialPoint];
            if (firstComplexGlyph < 0) {
                break;
            }
            CRun *complexRun = CRunSplit(currentRun, firstComplexGlyph);
            [self drawComplexRun:complexRun
                              at:NSMakePoint(initialPoint.x + complexRun->x, initialPoint.y)];
            CRunFree(complexRun);
        }
    } else {
        // Complex
        [self drawComplexRun:currentRun
                          at:NSMakePoint(initialPoint.x + currentRun->x, initialPoint.y)];
    }

    // Draw underline
    if (currentRun->attrs.underline) {
        [currentRun->attrs.color set];
        NSRectFill(NSMakeRect(startPoint.x,
                              startPoint.y + _cellSize.height - 2,
                              runWidth,
                              1));
    }
}

// Note: caller must nil out _selectedFont after the graphics context becomes invalid.
- (int)drawSimpleRun:(CRun *)currentRun
                 ctx:(CGContextRef)ctx
        initialPoint:(NSPoint)initialPoint {
    int firstMissingGlyph;
    CGGlyph *glyphs = CRunGetGlyphs(currentRun, &firstMissingGlyph);
    if (!glyphs) {
        return -1;
    }

    size_t numCodes = currentRun->length;
    size_t length = numCodes;
    if (firstMissingGlyph >= 0) {
        length = firstMissingGlyph;
    }
    [self selectFont:currentRun->attrs.fontInfo.font inContext:ctx];
    CGContextSetFillColorSpace(ctx, [[currentRun->attrs.color colorSpace] CGColorSpace]);
    int componentCount = [currentRun->attrs.color numberOfComponents];

    CGFloat components[componentCount];
    [currentRun->attrs.color getComponents:components];
    CGContextSetFillColor(ctx, components);

    double y = initialPoint.y + _cellSize.height + currentRun->attrs.fontInfo.baselineOffset;
    int x = initialPoint.x + currentRun->x;
    // Flip vertically and translate to (x, y).
    CGFloat m21 = 0.0;
    if (currentRun->attrs.fakeItalic) {
        m21 = 0.2;
    }
    CGContextSetTextMatrix(ctx, CGAffineTransformMake(1.0,  0.0,
                                                      m21, -1.0,
                                                      x, y));

    void *advances = CRunGetAdvances(currentRun);
    CGContextShowGlyphsWithAdvances(ctx, glyphs, advances, length);

    if (currentRun->attrs.fakeBold) {
        // If anti-aliased, drawing twice at the same position makes the strokes thicker.
        // If not anti-alised, draw one pixel to the right.
        CGContextSetTextMatrix(ctx, CGAffineTransformMake(1.0,  0.0,
                                                          m21, -1.0,
                                                          x + (currentRun->attrs.antiAlias ? _antiAliasedShift : 1),
                                                          y));

        CGContextShowGlyphsWithAdvances(ctx, glyphs, advances, length);
    }
    return firstMissingGlyph;
}

- (void)drawImageCellInRun:(CRun *)run atPoint:(NSPoint)point {
    ImageInfo *imageInfo = GetImageInfo(run->attrs.imageCode);
    NSImage *image =
        [imageInfo imageEmbeddedInRegionOfSize:NSMakeSize(_cellSize.width * imageInfo.size.width,
                                                          _cellSize.height * imageInfo.size.height)];
    NSSize chunkSize = NSMakeSize(image.size.width / imageInfo.size.width,
                                  image.size.height / imageInfo.size.height);

    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:point.x yBy:point.y + _cellSize.height];
    [transform scaleXBy:1.0 yBy:-1.0];
    [transform concat];
    
    NSColor *backgroundColor = [_colorMap mutedColorForKey:kColorMapBackground];
    [backgroundColor set];
    NSRectFill(NSMakeRect(0, 0, _cellSize.width * run->numImageCells, _cellSize.height));
    
    [image drawInRect:NSMakeRect(0, 0, _cellSize.width * run->numImageCells, _cellSize.height)
             fromRect:NSMakeRect(chunkSize.width * run->attrs.imageColumn,
                                 image.size.height - _cellSize.height - chunkSize.height * run->attrs.imageLine,
                                 chunkSize.width * run->numImageCells,
                                 chunkSize.height)
            operation:NSCompositeSourceOver
             fraction:1];
    [NSGraphicsContext restoreGraphicsState];
}

- (BOOL)complexRunIsBoxDrawingCell:(CRun *)complexRun {
    switch (complexRun->key) {
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL:
            return YES;
        default:
            return NO;
    }
}

- (void)drawBoxDrawingCellInRun:(CRun *)complexRun at:(NSPoint)pos {
    NSBezierPath *path = [self bezierPathForBoxDrawingCode:complexRun->key];
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    [ctx saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:pos.x yBy:pos.y];
    [transform concat];
    [complexRun->attrs.color set];
    [path stroke];
    [ctx restoreGraphicsState];
}

- (NSAttributedString *)attributedStringForComplexRun:(CRun *)complexRun {
    PTYFontInfo *fontInfo = complexRun->attrs.fontInfo;
    NSColor *color = complexRun->attrs.color;
    NSString *str = complexRun->string;
    NSDictionary *attrs = @{ NSFontAttributeName: fontInfo.font,
                             NSForegroundColorAttributeName: color };

    return [[[NSAttributedString alloc] initWithString:str
                                            attributes:attrs] autorelease];
}

- (void)drawStringWithCombiningMarksInRun:(CRun *)complexRun at:(NSPoint)pos {
    PTYFontInfo *fontInfo = complexRun->attrs.fontInfo;
    BOOL fakeBold = complexRun->attrs.fakeBold;
    BOOL fakeItalic = complexRun->attrs.fakeItalic;
    BOOL antiAlias = complexRun->attrs.antiAlias;

    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    NSColor *color = complexRun->attrs.color;

    [ctx saveGraphicsState];
    [ctx setCompositingOperation:NSCompositeSourceOver];

    // This renders characters with combining marks better but is slower.
    NSAttributedString *attributedString = [self attributedStringForComplexRun:complexRun];

    // We used to use -[NSAttributedString drawWithRect:options] but
    // it does a lousy job rendering multiple combining marks. This is close
    // to what WebKit does and appears to be the highest quality text
    // rendering available.

    CTLineRef lineRef = CTLineCreateWithAttributedString((CFAttributedStringRef)attributedString);
    CFArrayRef runs = CTLineGetGlyphRuns(lineRef);
    CGContextRef cgContext = (CGContextRef) [ctx graphicsPort];
    CGContextSetFillColorWithColor(cgContext, [self cgColorForColor:color]);
    CGContextSetStrokeColorWithColor(cgContext, [self cgColorForColor:color]);

    CGFloat c = 0.0;
    if (fakeItalic) {
        c = 0.2;
    }

    const CGFloat ty = pos.y + fontInfo.baselineOffset + _cellSize.height;
    CGAffineTransform textMatrix = CGAffineTransformMake(1.0,  0.0,
                                                         c, -1.0,
                                                         pos.x, ty);
    CGContextSetTextMatrix(cgContext, textMatrix);

    for (CFIndex j = 0; j < CFArrayGetCount(runs); j++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, j);
        size_t length = CTRunGetGlyphCount(run);
        const CGGlyph *buffer = CTRunGetGlyphsPtr(run);
        const CGPoint *positions = CTRunGetPositionsPtr(run);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, cgContext);

        if (fakeBold) {
            CGContextTranslateCTM(cgContext, antiAlias ? _antiAliasedShift : 1, 0);
            CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, cgContext);
            CGContextTranslateCTM(cgContext, antiAlias ? -_antiAliasedShift : -1, 0);
        }
    }
    CFRelease(lineRef);
    [ctx restoreGraphicsState];
}

// TODO: Support fake italic
- (void)drawAttributedStringInRun:(CRun *)complexRun at:(NSPoint)pos {
    PTYFontInfo *fontInfo = complexRun->attrs.fontInfo;
    BOOL fakeBold = complexRun->attrs.fakeBold;
    BOOL antiAlias = complexRun->attrs.antiAlias;

    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];

    [ctx saveGraphicsState];
    [ctx setCompositingOperation:NSCompositeSourceOver];

    CGFloat width = CRunGetAdvances(complexRun)[0].width;
    NSAttributedString* attributedString = [self attributedStringForComplexRun:complexRun];

    // Note that drawInRect doesn't use the right baseline, but drawWithRect
    // does.
    //
    // This technique was picked because it can find glyphs that aren't in the
    // selected font (e.g., tests/radical.txt). It doesn't draw combining marks
    // as well as CTFontDrawGlyphs (though they are generally passable).  It
    // fails badly in two known cases:
    // 1. Enclosing marks (q in a circle shows as a q)
    // 2. U+239d, a part of a paren for graphics drawing, doesn't quite render
    //    right (though it appears to need to render in another char's cell).
    // Other rejected approaches included using CTFontGetGlyphsForCharacters+
    // CGContextShowGlyphsWithAdvances, which doesn't render thai characters
    // correctly in UTF-8-demo.txt.
    //
    // We use width*2 so that wide characters that are not double width chars
    // render properly. These are font-dependent. See tests/suits.txt for an
    // example.
    [attributedString drawWithRect:NSMakeRect(pos.x,
                                              pos.y + fontInfo.baselineOffset + _cellSize.height,
                                              width * 2,
                                              _cellSize.height)
                           options:0];
    if (fakeBold) {
        // If anti-aliased, drawing twice at the same position makes the strokes thicker.
        // If not anti-alised, draw one pixel to the right.
        [attributedString drawWithRect:NSMakeRect(pos.x + (antiAlias ? 0 : 1),
                                                  pos.y + fontInfo.baselineOffset + _cellSize.height,
                                                  width*2,
                                                  _cellSize.height)
                               options:0];
    }

    [ctx restoreGraphicsState];
}

- (void)drawComplexRun:(CRun *)complexRun at:(NSPoint)pos {
    // Handle cells that are part of an image.
    if (complexRun->attrs.imageCode > 0) {
        [self drawImageCellInRun:complexRun atPoint:pos];
    } else if ([self complexRunIsBoxDrawingCell:complexRun]) {
        // Special box-drawing cells don't use the font so they look prettier.
        [self drawBoxDrawingCellInRun:complexRun at:pos];
    } else if (StringContainsCombiningMark(complexRun->string)) {
        // High-quality but slow rendering, needed especially for multiple combining marks.
        [self drawStringWithCombiningMarksInRun:complexRun at:pos];
    } else {
        // Faster (not fast, but faster) than drawStringWithCombiningMarksInRun. AFAICT this is only
        // used for surrogate pairs, so it's a candidate for deletion.
        [self drawAttributedStringInRun:complexRun at:pos];
    }

}

- (BOOL)drawInputMethodEditorTextAt:(int)xStart
                                  y:(int)yStart
                              width:(int)width
                             height:(int)height
                       cursorHeight:(double)cursorHeight
                                ctx:(CGContextRef)ctx {
    iTermColorMap *colorMap = _colorMap;

    // draw any text for NSTextInput
    if ([self hasMarkedText]) {
        NSString* str = [_markedText string];
        const int maxLen = [str length] * kMaxParts;
        screen_char_t buf[maxLen];
        screen_char_t fg = {0}, bg = {0};
        int len;
        int cursorIndex = (int)_inputMethodSelectedRange.location;
        StringToScreenChars(str,
                            buf,
                            fg,
                            bg,
                            &len,
                            _ambiguousIsDoubleWidth,
                            &cursorIndex,
                            NULL,
                            _useHFSPlusMapping);
        int cursorX = 0;
        int baseX = floor(xStart * _cellSize.width + MARGIN);
        int i;
        int y = (yStart + _numberOfLines - height) * _cellSize.height;
        int cursorY = y;
        int x = baseX;
        int preWrapY = 0;
        BOOL justWrapped = NO;
        BOOL foundCursor = NO;
        for (i = 0; i < len; ) {
            const int remainingCharsInBuffer = len - i;
            const int remainingCharsInLine = width - xStart;
            int charsInLine = MIN(remainingCharsInLine,
                                  remainingCharsInBuffer);
            int skipped = 0;
            if (charsInLine + i < len &&
                buf[charsInLine + i].code == DWC_RIGHT) {
                // If we actually drew 'charsInLine' chars then half of a
                // double-width char would be drawn. Skip it and draw it on the
                // next line.
                skipped = 1;
                --charsInLine;
            }
            // Draw the background.
            NSRect r = NSMakeRect(x,
                                  y,
                                  charsInLine * _cellSize.width,
                                  _cellSize.height);
            if (!colorMap.dimOnlyText) {
                [[colorMap dimmedColorForKey:kColorMapBackground] set];
            } else {
                [[colorMap mutedColorForKey:kColorMapBackground] set];
            }
            NSRectFill(r);

            // Draw the characters.
            CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:charsInLine];
            CRun *run = [self constructTextRuns:NSMakePoint(x, y)
                                           line:buf
                                            row:y
                                       selected:NO
                                     indexRange:NSMakeRange(i, charsInLine)
                                backgroundColor:nil
                                        matches:nil
                                        storage:storage];
            if (run) {
                [self drawRunsAt:NSMakePoint(x, y) run:run storage:storage context:ctx];
                CRunFree(run);
            }

            // Draw an underline.
            NSColor *foregroundColor = [colorMap mutedColorForKey:kColorMapForeground];
            [foregroundColor set];
            NSRect s = NSMakeRect(x,
                                  y + _cellSize.height - 1,
                                  charsInLine * _cellSize.width,
                                  1);
            NSRectFill(s);

            // Save the cursor's cell coords
            if (i <= cursorIndex && i + charsInLine > cursorIndex) {
                // The char the cursor is at was drawn in this line.
                const int cellsAfterStart = cursorIndex - i;
                cursorX = x + _cellSize.width * cellsAfterStart;
                cursorY = y;
                foundCursor = YES;
            }

            // Advance the cell and screen coords.
            xStart += charsInLine + skipped;
            if (xStart == width) {
                justWrapped = YES;
                preWrapY = y;
                xStart = 0;
                yStart++;
            } else {
                justWrapped = NO;
            }
            x = floor(xStart * _cellSize.width + MARGIN);
            y = (yStart + _numberOfLines - height) * _cellSize.height;
            i += charsInLine;
        }

        if (!foundCursor && i == cursorIndex) {
            if (justWrapped) {
                cursorX = MARGIN + width * _cellSize.width;
                cursorY = preWrapY;
            } else {
                cursorX = x;
                cursorY = y;
            }
        }
        const double kCursorWidth = 2.0;
        double rightMargin = MARGIN + _gridSize.width * _cellSize.width;
        if (cursorX + kCursorWidth >= rightMargin) {
            // Make sure the cursor doesn't draw in the margin. Shove it left
            // a little bit so it fits.
            cursorX = rightMargin - kCursorWidth;
        }
        NSRect cursorFrame = NSMakeRect(cursorX,
                                        cursorY,
                                        2.0,
                                        cursorHeight);
        _imeCursorLastPos = cursorFrame.origin;
        [self.delegate drawingHelperUpdateFindCursorView];
        [[colorMap dimmedColorForColor:[NSColor colorWithCalibratedRed:1.0
                                                                 green:1.0
                                                                  blue:0
                                                                 alpha:1.0]] set];
        NSRectFill(cursorFrame);

        return TRUE;
    }
    return FALSE;
}

- (void)drawCharacter:(screen_char_t)screenChar
              fgColor:(int)fgColor
              fgGreen:(int)fgGreen
               fgBlue:(int)fgBlue
          fgColorMode:(ColorMode)fgColorMode
               fgBold:(BOOL)fgBold
              fgFaint:(BOOL)fgFaint
                  AtX:(double)X
                    Y:(double)Y
          doubleWidth:(BOOL)double_width
        overrideColor:(NSColor*)overrideColor
              context:(CGContextRef)ctx
      backgroundColor:(NSColor *)backgroundColor {
    screen_char_t temp = screenChar;
    temp.foregroundColor = fgColor;
    temp.fgGreen = fgGreen;
    temp.fgBlue = fgBlue;
    temp.foregroundColorMode = fgColorMode;
    temp.bold = fgBold;
    temp.faint = fgFaint;

    CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:1];
    // Draw the characters.
    CRun *run = [self constructTextRuns:NSMakePoint(X, Y)
                                   line:&temp
                                    row:(int)Y
                               selected:NO
                             indexRange:NSMakeRange(0, 1)
                        backgroundColor:backgroundColor
                                matches:nil
                                storage:storage];
    if (run) {
        CRun *head = run;
        // If an override color is given, change the runs' colors.
        if (overrideColor) {
            while (run) {
                CRunAttrsSetColor(&run->attrs, run->storage, overrideColor);
                run = run->next;
            }
        }
        [self drawRunsAt:NSMakePoint(X, Y) run:head storage:storage context:ctx];
        CRunFree(head);
    }

    // draw underline
    if (screenChar.underline && screenChar.code) {
        if (overrideColor) {
            [overrideColor set];
        } else {
            [[_delegate drawingHelperColorForCode:fgColor
                                            green:fgGreen
                                             blue:fgBlue
                                        colorMode:ColorModeAlternate
                                             bold:fgBold
                                            faint:fgFaint
                                     isBackground:NO] set];
        }

        NSRectFill(NSMakeRect(X,
                              Y + _cellSize.height - 2,
                              double_width ? _cellSize.width * 2 : _cellSize.width,
                              1));
    }
}

#pragma mark - Drawing: Cursor

- (void)drawCursor {
    DLog(@"drawCursor");

    if (![self cursorInDocumentVisibleRect]) {
        return;
    }

    // Update the last time the cursor moved.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!VT100GridCoordEquals(_cursorCoord, _oldCursorPosition)) {
        _lastTimeCursorMoved = now;
    }

    if ([self shouldDrawCursor]) {
        // Get the character that's under the cursor.
        screen_char_t *theLine = [self.delegate drawingHelperLineAtScreenIndex:_cursorCoord.y];
        BOOL isDoubleWidth;
        screen_char_t screenChar = [self charForCursorAtColumn:_cursorCoord.x
                                                        inLine:theLine
                                                   doubleWidth:&isDoubleWidth];

        // Update the "find cursor" view.
        [self.delegate drawingHelperUpdateFindCursorView];

        // Get the color of the cursor.
        NSColor *cursorColor;
        cursorColor = [self backgroundColorForCursorOnLine:theLine
                                                  atColumn:_cursorCoord.x
                                                screenChar:screenChar];

        // Draw the cursor.
        switch (_cursorType) {
            case CURSOR_BOX:
                [self drawBoxCursorOfSize:[self cursorSize]
                            isDoubleWidth:isDoubleWidth
                                  atPoint:[self cursorOrigin]
                                   column:_cursorCoord.x
                               screenChar:screenChar
                          backgroundColor:cursorColor];

                break;

            case CURSOR_VERTICAL:
                [self drawVerticalBarCursorOfSize:[self cursorSize]
                                          atPoint:[self cursorOrigin]
                                            color:cursorColor];
                break;

            case CURSOR_UNDERLINE:
                [self drawUnderlineCursorOfSize:[self cursorSize]
                                  isDoubleWidth:isDoubleWidth
                                        atPoint:[self cursorOrigin]
                                          color:cursorColor];
                break;

            case CURSOR_DEFAULT:
                assert(false);
                break;
        }
    }
    
    _oldCursorPosition = _cursorCoord;
    [_selectedFont release];
    _selectedFont = nil;
}

- (void)drawSmartCursorCharacter:(screen_char_t)screenChar
                 backgroundColor:(NSColor *)backgroundColor
                             ctx:(CGContextRef)ctx
                     doubleWidth:(BOOL)doubleWidth
                      cursorSize:(NSSize)cursorSize
                    cursorOrigin:(NSPoint)cursorOrigin
                          column:(int)column {
    // Pick background color for text if is key window, otherwise use fg color for text.
    int fgColor;
    int fgGreen;
    int fgBlue;
    ColorMode fgColorMode;
    BOOL fgBold;
    BOOL fgFaint;
    BOOL isBold;
    BOOL isFaint;

    if (_isInKeyWindow) {
        // Draw a character in background color when
        // window is key.
        fgColor = screenChar.backgroundColor;
        fgGreen = screenChar.bgGreen;
        fgBlue = screenChar.bgBlue;
        fgColorMode = screenChar.backgroundColorMode;
        fgBold = NO;
        fgFaint = NO;
    } else {
        // Draw character in foreground color when there
        // is just a frame around it.
        fgColor = screenChar.foregroundColor;
        fgGreen = screenChar.fgGreen;
        fgBlue = screenChar.fgBlue;
        fgColorMode = screenChar.foregroundColorMode;
        fgBold = screenChar.bold;
        fgFaint = screenChar.faint;
    }
    isBold = screenChar.bold;
    isFaint = screenChar.faint;
    
    // Ensure text has enough contrast by making it black/white if the char's color would be close to the cursor bg.
    NSColor *proposedForeground =
        [[_delegate drawingHelperColorForCode:fgColor
                                        green:fgGreen
                                         blue:fgBlue
                                    colorMode:fgColorMode
                                         bold:fgBold
                                        faint:fgFaint
                                 isBackground:NO] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    NSColor *overrideColor = [self overrideColorForSmartCursorWithForegroundColor:proposedForeground
                                                                  backgroundColor:backgroundColor];

    BOOL saved = _useBrightBold;
    self.useBrightBold = NO;
    [self drawCharacter:screenChar
                fgColor:fgColor
                fgGreen:fgGreen
                 fgBlue:fgBlue
            fgColorMode:fgColorMode
                 fgBold:isBold
                fgFaint:isFaint
                    AtX:column * _cellSize.width + MARGIN
                      Y:cursorOrigin.y + cursorSize.height - _cellSize.height
            doubleWidth:doubleWidth
          overrideColor:overrideColor
                context:ctx
        backgroundColor:nil];
    self.useBrightBold = saved;
}

- (void)drawBoxCursorOfSize:(NSSize)cursorSize
              isDoubleWidth:(BOOL)double_width
                    atPoint:(NSPoint)cursorOrigin
                     column:(int)column
                 screenChar:(screen_char_t)screenChar
            backgroundColor:(NSColor *)bgColor {
    DLog(@"draw cursor box at %f,%f size %fx%f",
         (float)cursorOrigin.x, (float)cursorOrigin.y,
         (float)ceil(cursorSize.width * (double_width ? 2 : 1)), cursorSize.height);

    // Draw the colored box/frame
    [bgColor set];
    const BOOL frameOnly = !((_isInKeyWindow && _textViewIsActiveSession) ||
                             _shouldDrawFilledInCursor);
    NSRect cursorRect = NSMakeRect(cursorOrigin.x,
                                   cursorOrigin.y,
                                   ceil(cursorSize.width * (double_width ? 2 : 1)),
                                   cursorSize.height);
    if (frameOnly) {
        NSFrameRect(cursorRect);
    } else {
        NSRectFill(cursorRect);
    }

    // Draw the character.
    if (screenChar.code) {
        // Have a char at the cursor position.
        CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
        if (_useSmartCursorColor && !frameOnly) {
            [self drawSmartCursorCharacter:screenChar
                               backgroundColor:bgColor
                                           ctx:ctx
                                   doubleWidth:double_width
                                    cursorSize:cursorSize
                                  cursorOrigin:cursorOrigin
                                        column:column];
        } else {
            // Non-smart cursor or cursor is frame
            int theColor;
            int theGreen;
            int theBlue;
            ColorMode theMode;
            BOOL isBold;
            BOOL isFaint;
            if (_isInKeyWindow) {
                theColor = ALTSEM_CURSOR;
                theGreen = 0;
                theBlue = 0;
                theMode = ColorModeAlternate;
            } else {
                theColor = screenChar.foregroundColor;
                theGreen = screenChar.fgGreen;
                theBlue = screenChar.fgBlue;
                theMode = screenChar.foregroundColorMode;
            }
            isBold = screenChar.bold;
            isFaint = screenChar.faint;
            [self drawCharacter:screenChar
                        fgColor:theColor
                        fgGreen:theGreen
                         fgBlue:theBlue
                    fgColorMode:theMode
                         fgBold:isBold
                        fgFaint:isFaint
                            AtX:column * _cellSize.width + MARGIN
                              Y:cursorOrigin.y + cursorSize.height - _cellSize.height
                    doubleWidth:double_width
                  overrideColor:nil
                        context:ctx
                backgroundColor:bgColor];  // Pass bgColor so min contrast can apply
        }
    }
}

- (void)drawVerticalBarCursorOfSize:(NSSize)cursorSize
                            atPoint:(NSPoint)cursorOrigin
                              color:(NSColor *)color {
    DLog(@"draw cursor vline at %f,%f size %fx%f",
         (float)cursorOrigin.x, (float)cursorOrigin.y, (float)1, cursorSize.height);
    [color set];
    NSRectFill(NSMakeRect(cursorOrigin.x, cursorOrigin.y, 1, cursorSize.height));
}

- (void)drawUnderlineCursorOfSize:(NSSize)cursorSize
                    isDoubleWidth:(BOOL)double_width
                          atPoint:(NSPoint)cursorOrigin
                            color:(NSColor *)color {
    DLog(@"draw cursor underline at %f,%f size %fx%f",
         (float)cursorOrigin.x, (float)cursorOrigin.y,
         (float)ceil(cursorSize.width * (double_width ? 2 : 1)), 2.0);
    [color set];
    NSRectFill(NSMakeRect(cursorOrigin.x,
                          cursorOrigin.y + _cellSize.height - 2,
                          ceil(cursorSize.width * (double_width ? 2 : 1)),
                          2));
}

#pragma mark - Background Run Construction

- (void)addBackgroundRun:(iTermBackgroundColorRun *)run
                 toArray:(NSMutableArray *)runs
                endingAt:(int)end {  // end is the location after the last location in the run
    // Update the range's length.
    NSRange range = run->range;
    range.length = end - range.location;
    run->range = range;

    // Add it to the array.
    iTermBoxedBackgroundColorRun *box = [[[iTermBoxedBackgroundColorRun alloc] init] autorelease];
    memcpy(box.valuePointer, run, sizeof(*run));
    [runs addObject:box];
}

- (NSArray *)backgroundRunsInLine:(int)line
                      withinRange:(NSRange)charRange
                          matches:(NSData *)matches
                         anyBlink:(BOOL *)anyBlinkPtr
                    textExtractor:(iTermTextExtractor *)extractor {
    NSMutableArray *runs = [NSMutableArray array];
    screen_char_t* theLine = [self.delegate drawingHelperLineAtIndex:line];
    NSIndexSet *selectedIndexes = [_selection selectedIndexesOnLine:line];
    int width = _gridSize.width;
    iTermBackgroundColorRun previous;
    iTermBackgroundColorRun current;
    BOOL first = YES;
    int j;
    for (j = charRange.location; j < charRange.location + charRange.length; j++) {
        int x = j;
        if (theLine[j].code == DWC_RIGHT) {
            x = j - 1;
        }
        iTermMakeBackgroundColorRun(&current,
                                    theLine,
                                    VT100GridCoordMake(x, line),
                                    extractor,
                                    selectedIndexes,
                                    matches,
                                    width);
        if (theLine[x].blink) {
            *anyBlinkPtr = YES;
        }
        if (first) {
            current.range = NSMakeRange(j, 0);
            first = NO;
        } else if (!iTermBackgroundColorRunsEqual(&current, &previous)) {
            [self addBackgroundRun:&previous toArray:runs endingAt:j];

            current.range = NSMakeRange(j, 0);
        }

        previous = current;
    }
    if (!first) {
        [self addBackgroundRun:&current toArray:runs endingAt:j];
    }
    
    return runs;
}

// Augments the "real" selection (as reported by iTermSelection) by adding TAB_FILLER characters
// preceding a selected TAB.
- (NSIndexSet *)selectedIndexesInLine:(int)y {
    NSIndexSet *basicIndexes = [self.selection selectedIndexesOnLine:y];
    if (!basicIndexes.count) {
        return basicIndexes;
    }

    // Add in tab fillers preceding already-selected tabs.
    NSMutableIndexSet *indexes = [[basicIndexes mutableCopy] autorelease];
    const int width = _gridSize.width;
    screen_char_t buffer[width + 1];
    screen_char_t *theLine = [_delegate drawingHelperCopyLineAtIndex:y toBuffer:buffer];
    BOOL active = NO;
    for (int x = width - 1; x >= 0; x--) {
        if (active) {
            if (theLine[x].code == TAB_FILLER && !theLine[x].complexChar) {
                // Found a tab filler preceding a selected tab. Mark it selected.
                [indexes addIndex:x];
            } else {
                // Found something that isn't a tab filler preceding a selected tab. Stop looking for
                // tab fillers.
                active = NO;
            }
        } else if (theLine[x].code == '\t' &&
                   !theLine[x].complexChar &&
                   [indexes containsIndex:x]) {
            // Found a selected tab. Begin adding tab fillers preceding it.
            active = YES;
        }
    }
    return indexes;
}

#pragma mark - Text Run Construction

- (CRun *)constructTextRuns:(NSPoint)initialPoint
                       line:(screen_char_t *)theLine
                        row:(int)row
                   selected:(BOOL)bgselected
                 indexRange:(NSRange)indexRange
            backgroundColor:(NSColor *)bgColor
                    matches:(NSData *)matches
                    storage:(CRunStorage *)storage {
    const int width = _gridSize.width;
    iTermColorMap *colorMap = self.colorMap;
    BOOL inUnderlinedRange = NO;
    CRun *firstRun = NULL;
    CAttrs attrs = { 0 };
    CRun *currentRun = NULL;
    const char* matchBytes = [matches bytes];
    int lastForegroundColor = -1;
    int lastFgGreen = -1;
    int lastFgBlue = -1;
    int lastForegroundColorMode = -1;
    int lastBold = 2;  // Bold is a one-bit field so it can never equal 2.
    int lastFaint = 2;  // Same for faint
    NSColor *lastColor = nil;
    CGFloat curX = 0;
    NSRange underlinedRange = [self underlinedRangeOnLine:row];
    const int underlineStartsAt = underlinedRange.location;
    const int underlineEndsAt = NSMaxRange(underlinedRange);
    const BOOL dimOnlyText = colorMap.dimOnlyText;
    const double minimumContrast = _minimumContrast;
    for (int i = indexRange.location; i < indexRange.location + indexRange.length; i++) {
        inUnderlinedRange = (i >= underlineStartsAt && i < underlineEndsAt);
        if (theLine[i].code == DWC_RIGHT) {
            continue;
        }

        BOOL doubleWidth = i < width - 1 && (theLine[i + 1].code == DWC_RIGHT);
        unichar thisCharUnichar = 0;
        NSString* thisCharString = nil;
        CGFloat thisCharAdvance;

        if (!_useNonAsciiFont || (theLine[i].code < 128 && !theLine[i].complexChar)) {
            attrs.antiAlias = _asciiAntiAlias;
        } else {
            attrs.antiAlias = _nonAsciiAntiAlias;
        }
        BOOL isSelection = NO;

        // Figure out the color for this char.
        if (bgselected) {
            // Is a selection.
            isSelection = YES;
            // NOTE: This could be optimized by caching the color.
            CRunAttrsSetColor(&attrs, storage, [colorMap dimmedColorForKey:kColorMapSelectedText]);
        } else {
            // Not a selection.
            if (_reverseVideo &&
                theLine[i].foregroundColor == ALTSEM_DEFAULT &&
                theLine[i].foregroundColorMode == ColorModeAlternate) {
                // Has default foreground color so use background color.
                if (!dimOnlyText) {
                    CRunAttrsSetColor(&attrs, storage,
                                      [colorMap dimmedColorForKey:kColorMapBackground]);
                } else {
                    CRunAttrsSetColor(&attrs,
                                      storage,
                                      [colorMap mutedColorForKey:kColorMapBackground]);
                }
            } else {
                if (theLine[i].foregroundColor == lastForegroundColor &&
                    theLine[i].fgGreen == lastFgGreen &&
                    theLine[i].fgBlue == lastFgBlue &&
                    theLine[i].foregroundColorMode == lastForegroundColorMode &&
                    theLine[i].bold == lastBold &&
                    theLine[i].faint == lastFaint) {
                    // Looking up colors with -drawingHelperColorForCode:... is expensive and it's common to
                    // have consecutive characters with the same color.
                    CRunAttrsSetColor(&attrs, storage, lastColor);
                } else {
                    // Not reversed or not subject to reversing (only default
                    // foreground color is drawn in reverse video).
                    lastForegroundColor = theLine[i].foregroundColor;
                    lastFgGreen = theLine[i].fgGreen;
                    lastFgBlue = theLine[i].fgBlue;
                    lastForegroundColorMode = theLine[i].foregroundColorMode;
                    lastBold = theLine[i].bold;
                    lastFaint = theLine[i].faint;
                    CRunAttrsSetColor(&attrs,
                                      storage,
                                      [_delegate drawingHelperColorForCode:theLine[i].foregroundColor
                                                                     green:theLine[i].fgGreen
                                                                      blue:theLine[i].fgBlue
                                                                 colorMode:theLine[i].foregroundColorMode
                                                                      bold:theLine[i].bold
                                                                     faint:theLine[i].faint
                                                              isBackground:NO]);
                    lastColor = attrs.color;
                }
            }
        }

        if (matches && !isSelection) {
            // Test if this is a highlighted match from a find.
            int theIndex = i / 8;
            int mask = 1 << (i & 7);
            if (theIndex < [matches length] && matchBytes[theIndex] & mask) {
                CRunAttrsSetColor(&attrs,
                                  storage,
                                  [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:1]);
            }
        }

        if (minimumContrast > 0.001 && bgColor) {
            // TODO: Way too much time spent here. Use previous char's color if it is the same.
            CRunAttrsSetColor(&attrs,
                              storage,
                              [colorMap color:attrs.color withContrastAgainst:bgColor]);
        }
        BOOL drawable;
        if (_blinkingItemsVisible || !(_blinkAllowed && theLine[i].blink)) {
            // This char is either not blinking or during the "on" cycle of the
            // blink. It should be drawn.

            // Set the character type and its unichar/string.
            if (theLine[i].complexChar) {
                thisCharString = ComplexCharToStr(theLine[i].code);
                if (!thisCharString) {
                    // A bug that's happened more than once is that code gets
                    // set to 0 but complexChar is left set to true.
                    NSLog(@"No complex char for code %d", (int)theLine[i].code);
                    thisCharString = @"";
                    drawable = NO;
                } else {
                    drawable = YES;  // TODO: not all unicode is drawable
                }
            } else {
                thisCharString = nil;
                // Non-complex char
                // TODO: There are other spaces in unicode that should be supported.
                drawable = (theLine[i].code != 0 &&
                            theLine[i].code != '\t' &&
                            !(theLine[i].code >= ITERM2_PRIVATE_BEGIN &&
                              theLine[i].code <= ITERM2_PRIVATE_END));

                if (drawable) {
                    thisCharUnichar = theLine[i].code;
                }
            }
        } else {
            // Chatacter hidden because of blinking.
            drawable = NO;
        }

        if (theLine[i].underline || inUnderlinedRange) {
            // This is not as fast as possible, but is nice and simple. Always draw underlined text
            // even if it's just a blank.
            drawable = YES;
        }
        // Set all other common attributes.
        if (doubleWidth) {
            thisCharAdvance = _cellSize.width * 2;
        } else {
            thisCharAdvance = _cellSize.width;
        }

        if (drawable) {
            BOOL fakeBold = theLine[i].bold;
            BOOL fakeItalic = theLine[i].italic;
            attrs.fontInfo = [_delegate drawingHelperFontForChar:theLine[i].code
                                                       isComplex:theLine[i].complexChar
                                                      renderBold:&fakeBold
                                                    renderItalic:&fakeItalic];
            attrs.fakeBold = fakeBold;
            attrs.fakeItalic = fakeItalic;
            attrs.underline = theLine[i].underline || inUnderlinedRange;
            attrs.imageCode = theLine[i].image ? theLine[i].code : 0;
            attrs.imageColumn = theLine[i].foregroundColor;
            attrs.imageLine = theLine[i].backgroundColor;
            if (theLine[i].image) {
                thisCharString = @"I";
            }
            if (inUnderlinedRange && !_haveUnderlinedHostname) {
                attrs.color = [colorMap colorForKey:kColorMapLink];
            }
            if (!currentRun) {
                firstRun = currentRun = malloc(sizeof(CRun));
                CRunInitialize(currentRun, &attrs, storage, curX);
            }
            if (thisCharString) {
                currentRun = CRunAppendString(currentRun,
                                              &attrs,
                                              thisCharString,
                                              theLine[i].code,
                                              thisCharAdvance,
                                              curX);
            } else {
                currentRun = CRunAppend(currentRun, &attrs, thisCharUnichar, thisCharAdvance, curX);
            }
        } else {
            if (currentRun) {
                CRunTerminate(currentRun);
            }
            attrs.fakeBold = NO;
            attrs.fakeItalic = NO;
            attrs.fontInfo = nil;
        }
        
        curX += thisCharAdvance;
    }
    return firstRun;
}

- (NSRange)underlinedRangeOnLine:(int)row {
    if (_underlineRange.coordRange.start.x < 0) {
        return NSMakeRange(0, 0);
    }

    if (row == _underlineRange.coordRange.start.y && row == _underlineRange.coordRange.end.y) {
        // Whole underline is on one line.
        const int start = VT100GridWindowedRangeStart(_underlineRange).x;
        const int end = VT100GridWindowedRangeEnd(_underlineRange).x;
        return NSMakeRange(start, end - start);
    } else if (row == _underlineRange.coordRange.start.y) {
        // Underline spans multiple lines, starting at this one.
        const int start = VT100GridWindowedRangeStart(_underlineRange).x;
        const int end =
        _underlineRange.columnWindow.length > 0 ? VT100GridRangeMax(_underlineRange.columnWindow) + 1
        : _gridSize.width;
        return NSMakeRange(start, end - start);
    } else if (row == _underlineRange.coordRange.end.y) {
        // Underline spans multiple lines, ending at this one.
        const int start =
        _underlineRange.columnWindow.length > 0 ? _underlineRange.columnWindow.location : 0;
        const int end = VT100GridWindowedRangeEnd(_underlineRange).x;
        return NSMakeRange(start, end - start);
    } else if (row > _underlineRange.coordRange.start.y && row < _underlineRange.coordRange.end.y) {
        // Underline spans multiple lines. This is not the first or last line, so all chars
        // in it are underlined.
        const int start =
        _underlineRange.columnWindow.length > 0 ? _underlineRange.columnWindow.location : 0;
        const int end =
        _underlineRange.columnWindow.length > 0 ? VT100GridRangeMax(_underlineRange.columnWindow) + 1
        : _gridSize.width;
        return NSMakeRange(start, end - start);
    } else {
        // No underline on this line.
        return NSMakeRange(0, 0);
    }
}

#pragma mark - Cursor Utilities

- (CGFloat)cursorHeight {
    return _cellSize.height;
}

- (NSSize)cursorSize {
    return NSMakeSize(MIN(_cellSize.width, _cellSizeWithoutSpacing.width), self.cursorHeight);
}

// screenChar isn't directly inferrable from theLine because it gets tweaked for various edge cases.
- (NSColor *)backgroundColorForCursorOnLine:(screen_char_t *)theLine
                                   atColumn:(int)column
                                 screenChar:(screen_char_t)screenChar {
    if (_isFindingCursor) {
        DLog(@"Use random cursor color");
        return [self _randomColor];
    }

    if (_useSmartCursorColor) {
        return [[self smartCursorColorForChar:screenChar
                                       column:column
                                  lineOfChars:theLine] colorWithAlphaComponent:1.0];
    } else {
        return [[_colorMap colorForKey:kColorMapCursor] colorWithAlphaComponent:1.0];
    }
}

- (NSColor *)smartCursorColorForChar:(screen_char_t)screenChar
                              column:(int)column
                         lineOfChars:(screen_char_t *)theLine {
    int row = _cursorCoord.y;

    screen_char_t* lineAbove = nil;
    screen_char_t* lineBelow = nil;
    if (row > 0) {
        lineAbove = [_delegate drawingHelperLineAtIndex:row - 1];
    }
    if (row + 1 < _gridSize.height) {
        lineBelow = [_delegate drawingHelperLineAtIndex:row + 1];
    }

    NSColor *bgColor;
    if (_reverseVideo) {
        bgColor = [_delegate drawingHelperColorForCode:screenChar.backgroundColor
                                                 green:screenChar.bgGreen
                                                  blue:screenChar.bgBlue
                                             colorMode:screenChar.backgroundColorMode
                                                  bold:screenChar.bold
                                                 faint:screenChar.faint
                                          isBackground:NO];
    } else {
        bgColor = [_delegate drawingHelperColorForCode:screenChar.foregroundColor
                                                 green:screenChar.fgGreen
                                                  blue:screenChar.fgBlue
                                             colorMode:screenChar.foregroundColorMode
                                                  bold:screenChar.bold
                                                 faint:screenChar.faint
                                          isBackground:NO];
    }

    NSMutableArray* constraints = [NSMutableArray arrayWithCapacity:2];
    CGFloat bgBrightness = [bgColor perceivedBrightness];
    if (column > 0) {
        [constraints addObject:@([self brightnessOfCharBackground:theLine[column - 1]])];
    }
    if (column < _gridSize.width) {
        [constraints addObject:@([self brightnessOfCharBackground:theLine[column + 1]])];
    }
    if (lineAbove) {
        [constraints addObject:@([self brightnessOfCharBackground:lineAbove[column]])];
    }
    if (lineBelow) {
        [constraints addObject:@([self brightnessOfCharBackground:lineBelow[column]])];
    }
    if ([self minimumDistanceOf:bgBrightness fromAnyValueIn:constraints] <
        [iTermAdvancedSettingsModel smartCursorColorBgThreshold]) {
        CGFloat b = [self farthestValueFromAnyValueIn:constraints];
        bgColor = [NSColor colorWithCalibratedRed:b green:b blue:b alpha:1];
    }
    return bgColor;
}

// Return the value in 'values' closest to target.
- (CGFloat)minimumDistanceOf:(CGFloat)target fromAnyValueIn:(NSArray*)values {
    CGFloat md = 1;
    for (NSNumber* n in values) {
        CGFloat dist = fabs(target - [n doubleValue]);
        if (dist < md) {
            md = dist;
        }
    }
    return md;
}

// Return the value between 0 and 1 that is farthest from any value in 'constraints'.
- (CGFloat)farthestValueFromAnyValueIn:(NSArray*)constraints {
    if ([constraints count] == 0) {
        return 0;
    }

    NSArray* sortedConstraints = [constraints sortedArrayUsingSelector:@selector(compare:)];
    double minVal = [[sortedConstraints objectAtIndex:0] doubleValue];
    double maxVal = [[sortedConstraints lastObject] doubleValue];

    CGFloat bestDistance = 0;
    CGFloat bestValue = -1;
    CGFloat prev = [[sortedConstraints objectAtIndex:0] doubleValue];
    for (NSNumber* np in sortedConstraints) {
        CGFloat n = [np doubleValue];
        const CGFloat dist = fabs(n - prev) / 2;
        if (dist > bestDistance) {
            bestDistance = dist;
            bestValue = (n + prev) / 2;
        }
        prev = n;
    }
    if (minVal > bestDistance) {
        bestValue = 0;
        bestDistance = minVal;
    }
    if (1 - maxVal > bestDistance) {
        bestValue = 1;
        bestDistance = 1 - maxVal;
    }
    DLog(@"Best distance is %f", (float)bestDistance);

    return bestValue;
}

- (double)brightnessOfCharBackground:(screen_char_t)c {
    return [[self backgroundColorForChar:c] perceivedBrightness];
}

- (NSColor *)backgroundColorForChar:(screen_char_t)c {
    if (_reverseVideo) {
        // reversed
        return [_delegate drawingHelperColorForCode:c.foregroundColor
                                              green:c.fgGreen
                                               blue:c.fgBlue
                                          colorMode:c.foregroundColorMode
                                               bold:c.bold
                                              faint:c.faint
                                       isBackground:YES];
    } else {
        // normal
        return [_delegate drawingHelperColorForCode:c.backgroundColor
                                              green:c.bgGreen
                                               blue:c.bgBlue
                                          colorMode:c.backgroundColorMode
                                               bold:NO
                                              faint:NO
                                       isBackground:YES];
    }
}

- (BOOL)cursorInDocumentVisibleRect {
    NSRect docVisibleRect = _scrollViewDocumentVisibleRect;
    int lastVisibleLine = docVisibleRect.origin.y / _cellSize.height + _gridSize.height;
    // TODO: I think there used to be an off-by-1 error here (1 wasn't subtracted from cursorY).
    int cursorLine = (_numberOfLines - _gridSize.height + _cursorCoord.y -
                      _scrollbackOverflow);
    if (cursorLine > lastVisibleLine) {
        return NO;
    }
    if (cursorLine < 0) {
        return NO;
    }
    return YES;
}

- (BOOL)shouldShowCursor {
    if (_cursorBlinking &&
        self.isInKeyWindow &&
        _textViewIsActiveSession &&
        [NSDate timeIntervalSinceReferenceDate] - _lastTimeCursorMoved > 0.5) {
        // Allow the cursor to blink if it is configured, the window is key, this session is active
        // in the tab, and the cursor has not moved for half a second.
        return _blinkingItemsVisible;
    } else {
        return YES;
    }
}

- (screen_char_t)charForCursorAtColumn:(int)column
                                inLine:(screen_char_t *)theLine
                           doubleWidth:(BOOL *)doubleWidth {
    screen_char_t screenChar = theLine[column];
    int width = _gridSize.width;
    if (column == width) {
        screenChar = theLine[column - 1];
        screenChar.code = 0;
        screenChar.complexChar = NO;
    }
    if (screenChar.code) {
        if (screenChar.code == DWC_RIGHT && column > 0) {
            column--;
            screenChar = theLine[column];
        }
        *doubleWidth = (column < width - 1) && (theLine[column+1].code == DWC_RIGHT);
    } else {
        *doubleWidth = NO;
    }
    return screenChar;
}

- (NSColor *)_randomColor {
    double r = arc4random() % 256;
    double g = arc4random() % 256;
    double b = arc4random() % 256;
    return [NSColor colorWithDeviceRed:r/255.0
                                 green:g/255.0
                                  blue:b/255.0
                                 alpha:1];
}

- (BOOL)shouldDrawCursor {
    BOOL shouldShowCursor = [self shouldShowCursor];
    int column = _cursorCoord.x;
    int row = _cursorCoord.y;
    int width = _gridSize.width;
    int height = _gridSize.height;

    // Draw the regular cursor only if there's not an IME open as it draws its
    // own cursor. Also, it must be not blinked-out, and it must be within the expected bounds of
    // the screen (which is just a sanity check, really).
    BOOL result = (![self hasMarkedText] &&
                   _cursorVisible &&
                   shouldShowCursor &&
                   column <= width &&
                   column >= 0 &&
                   row >= 0 &&
                   row < height);
    DLog(@"shouldDrawCursor: hasMarkedText=%d, cursorVisible=%d, showCursor=%d, column=%d, row=%d, "
         @"width=%d, height=%d. Result=%@",
         (int)[self hasMarkedText], (int)_cursorVisible, (int)shouldShowCursor, column, row,
         width, height, @(result));
    return result;
}

- (NSPoint)cursorOrigin {
    NSSize cursorSize = [self cursorSize];
    NSPoint cursorOrigin =
    NSMakePoint(floor(_cursorCoord.x * _cellSize.width + MARGIN),
                (_cursorCoord.y + _numberOfLines - _gridSize.height + 1) * _cellSize.height -
                cursorSize.height);
    return cursorOrigin;
}

- (NSColor *)overrideColorForSmartCursorWithForegroundColor:(NSColor *)proposedForeground
                                            backgroundColor:(NSColor *)backgroundColor {
    CGFloat fgBrightness = [proposedForeground perceivedBrightness];
    CGFloat bgBrightness = [backgroundColor perceivedBrightness];
    const double threshold = [iTermAdvancedSettingsModel smartCursorColorFgThreshold];
    if (fabs(fgBrightness - bgBrightness) < threshold) {
        // Foreground and background are very similar. Just use black and
        // white.
        if (bgBrightness < 0.5) {
            return [_colorMap dimmedColorForColor:[NSColor colorWithCalibratedRed:1
                                                                            green:1
                                                                             blue:1
                                                                            alpha:1]];
        } else {
            return [_colorMap dimmedColorForColor:[NSColor colorWithCalibratedRed:0
                                                                            green:0
                                                                             blue:0
                                                                            alpha:1]];
        }
    } else {
        return nil;
    }
}

#pragma mark - Coord/Rect Utilities

- (VT100GridCoordRange)coordRangeForRect:(NSRect)rect {
    return VT100GridCoordRangeMake(floor((rect.origin.x - MARGIN) / _cellSize.width),
                                   floor(rect.origin.y / _cellSize.height),
                                   ceil((NSMaxX(rect) - MARGIN) / _cellSize.width),
                                   ceil(NSMaxY(rect) / _cellSize.height));
}

- (NSRect)rectForCoordRange:(VT100GridCoordRange)coordRange {
    return NSMakeRect(coordRange.start.x * _cellSize.width + MARGIN,
                      coordRange.start.y * _cellSize.height,
                      (coordRange.end.x - coordRange.start.x) * _cellSize.width,
                      (coordRange.end.y - coordRange.start.y) * _cellSize.height);
}

- (NSRect)rectByGrowingRectByOneCell:(NSRect)innerRect {
    NSSize frameSize = _frame.size;
    NSPoint minPoint = NSMakePoint(MAX(0, innerRect.origin.x - _cellSize.width),
                                   MAX(0, innerRect.origin.y - _cellSize.height));
    NSPoint maxPoint = NSMakePoint(MIN(frameSize.width, NSMaxX(innerRect) + _cellSize.width),
                                   MIN(frameSize.height, NSMaxY(innerRect) + _cellSize.height));
    NSRect outerRect = NSMakeRect(minPoint.x,
                                  minPoint.y,
                                  maxPoint.x - minPoint.x,
                                  maxPoint.y - minPoint.y);
    return outerRect;
}

- (NSRange)rangeOfColumnsFrom:(CGFloat)x ofWidth:(CGFloat)width {
    NSRange charRange;
    charRange.location = MAX(0, (x - MARGIN) / _cellSize.width);
    charRange.length = ceil((x + width - MARGIN) / _cellSize.width) - charRange.location;
    if (charRange.location + charRange.length > _gridSize.width) {
        charRange.length = _gridSize.width - charRange.location;
    }
    return charRange;
}

// Not inclusive of end.x or end.y. Range of coords clipped to visible area and addressable lines.
- (VT100GridCoordRange)drawableCoordRangeForRect:(NSRect)rect {
    VT100GridCoordRange range;
    NSRange charRange = [self rangeOfColumnsFrom:rect.origin.x ofWidth:rect.size.width];
    range.start.x = charRange.location;
    range.end.x = charRange.location + charRange.length;

    // Where to start drawing?
    int lineStart = rect.origin.y / _cellSize.height;
    int lineEnd = ceil((rect.origin.y + rect.size.height) / _cellSize.height);

    // Ensure valid line ranges
    lineStart = MAX(0, lineStart);
    lineEnd = MIN(lineEnd, _numberOfLines);

    // Ensure lineEnd isn't beyond the bottom of the visible area.
    int visibleRows = ceil(_scrollViewContentSize.height / _cellSize.height);
    double hiddenAbove =
        _scrollViewDocumentVisibleRect.origin.y + _frame.origin.y;
    int firstVisibleRow = hiddenAbove / _cellSize.height;
    lineEnd = MIN(lineEnd, firstVisibleRow + visibleRows);

    range.start.y = lineStart;
    range.end.y = lineEnd;

    return range;
}

#pragma mark - Text Utilities

- (CGColorRef)cgColorForColor:(NSColor *)color {
    const NSInteger numberOfComponents = [color numberOfComponents];
    CGFloat components[numberOfComponents];
    CGColorSpaceRef colorSpace = [[color colorSpace] CGColorSpace];

    [color getComponents:(CGFloat *)&components];

    return (CGColorRef)[(id)CGColorCreate(colorSpace, components) autorelease];
}

- (NSBezierPath *)bezierPathForBoxDrawingCode:(int)code {
    //  0 1 2
    //  3 4 5
    //  6 7 8
    NSArray *points = nil;
    // The points array is a series of numbers from the above grid giving the
    // sequence of points to move the pen to.
    switch (code) {
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_LEFT:  // ┘
            points = @[ @(3), @(4), @(1) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_LEFT:  // ┐
            points = @[ @(3), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_RIGHT:  // ┌
            points = @[ @(7), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_RIGHT:  // └
            points = @[ @(1), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_HORIZONTAL:  // ┼
            points = @[ @(3), @(5), @(4), @(1), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_HORIZONTAL:  // ─
            points = @[ @(3), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_RIGHT:  // ├
            points = @[ @(1), @(4), @(5), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_LEFT:  // ┤
            points = @[ @(1), @(4), @(3), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_HORIZONTAL:  // ┴
            points = @[ @(3), @(4), @(1), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_HORIZONTAL:  // ┬
            points = @[ @(3), @(4), @(7), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL:  // │
            points = @[ @(1), @(7) ];
            break;
        default:
            break;
    }
    CGFloat xs[] = { 0, _cellSize.width / 2, _cellSize.width };
    CGFloat ys[] = { 0, _cellSize.height / 2, _cellSize.height };
    NSBezierPath *path = [NSBezierPath bezierPath];
    BOOL first = YES;
    for (NSNumber *n in points) {
        CGFloat x = xs[n.intValue % 3];
        CGFloat y = ys[n.intValue / 3];
        NSPoint p = NSMakePoint(x, y);
        if (first) {
            [path moveToPoint:p];
            first = NO;
        } else {
            [path lineToPoint:p];
        }
    }
    return path;
}

- (BOOL)hasMarkedText {
    return _inputMethodMarkedRange.length > 0;
}

#pragma mark - Background Utilities

- (NSColor *)defaultBackgroundColor {
    NSColor *aColor = [_delegate drawingHelperColorForCode:ALTSEM_DEFAULT
                                                     green:0
                                                      blue:0
                                                 colorMode:ColorModeAlternate
                                                      bold:NO
                                                     faint:NO
                                              isBackground:YES];
    double selectedAlpha = 1.0 - _transparency;
    aColor = [aColor colorWithAlphaComponent:selectedAlpha];
    return aColor;
}


- (NSColor *)selectionColorForCurrentFocus {
    if (_isFrontTextView) {
        return [_colorMap mutedColorForKey:kColorMapSelection];
    } else {
        return _unfocusedSelectionColor;
    }
}

- (void)selectFont:(NSFont *)font inContext:(CGContextRef)ctx {
    if (font != _selectedFont) {
        // This method is really slow so avoid doing it when it's not necessary
        CGContextSelectFont(ctx,
                            [[font fontName] UTF8String],
                            [font pointSize],
                            kCGEncodingMacRoman);
        [_selectedFont release];
        _selectedFont = [font retain];
    }
}

#pragma mark - Other Utility Methods

- (void)updateCachedMetrics {
    _frame = _delegate.frame;
    _visibleRect = _delegate.visibleRect;
    _scrollViewContentSize = _delegate.enclosingScrollView.contentSize;
    _scrollViewDocumentVisibleRect = _delegate.enclosingScrollView.documentVisibleRect;
}

- (void)startTiming {
    [_drawRectDuration startTimer];
    NSTimeInterval interval = [_drawRectInterval timeSinceTimerStarted];
    if ([_drawRectInterval haveStartedTimer]) {
        [_drawRectInterval addValue:interval];
    }
    [_drawRectInterval startTimer];
}

- (void)stopTiming {
    [_drawRectDuration addValue:[_drawRectDuration timeSinceTimerStarted]];
    NSLog(@"%p Moving average time draw rect is %04f, time between calls to drawRect is %04f",
          self, _drawRectDuration.value, _drawRectInterval.value);
}

@end
