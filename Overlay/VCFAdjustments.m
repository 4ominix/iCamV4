#import "VCFAdjustments.h"
#import "../Core/VCFSettings.h"

@implementation VCFAdjustments {
    UILabel *_title, *_zoomLabel;
    UIView *_separator;
    NSMutableDictionary<NSNumber *, UIButton *> *_buttons;
    BOOL _busy;
}

- (UIButton *)button:(NSString *)symbol tag:(NSInteger)tag label:(NSString *)label circle:(BOOL)circle {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.accessibilityLabel = label;
    button.tintColor = [UIColor colorWithWhite:.88 alpha:1];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    if (circle) {
        button.backgroundColor = [UIColor colorWithWhite:1 alpha:.045];
        button.layer.borderWidth = .75;
        button.layer.borderColor = [UIColor colorWithWhite:1 alpha:.15].CGColor;
    }
    [button addTarget:self action:tag == 12 ? @selector(close) : @selector(adjust:)
     forControlEvents:UIControlEventTouchUpInside];
    _buttons[@(tag)] = button;
    [self addSubview:button];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:.065 green:.075 blue:.085 alpha:.98];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = .5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:.13].CGColor;
        _buttons = [NSMutableDictionary new];

        _title = [UILabel new];
        _title.text = @"Camera control";
        _title.textColor = UIColor.whiteColor;
        [self addSubview:_title];

        [self button:@"arrow.counterclockwise" tag:10 label:@"Reset" circle:NO];
        [self button:@"chevron.right" tag:12 label:@"Close" circle:NO];
        [self button:@"arrow.up" tag:1 label:@"Move up" circle:YES];
        [self button:@"arrow.left" tag:2 label:@"Move left" circle:YES];

        UIButton *rotate = [self button:@"arrow.clockwise" tag:9 label:@"Rotate 90" circle:YES];
        rotate.tintColor = [UIColor colorWithRed:.31 green:.72 blue:.55 alpha:1];
        rotate.backgroundColor = [UIColor colorWithRed:.12 green:.34 blue:.26 alpha:.6];
        rotate.layer.borderColor = [rotate.tintColor colorWithAlphaComponent:.35].CGColor;

        [self button:@"arrow.right" tag:4 label:@"Move right" circle:YES];
        [self button:@"arrow.down" tag:5 label:@"Move down" circle:YES];

        _separator = [UIView new];
        _separator.backgroundColor = [UIColor colorWithWhite:1 alpha:.14];
        [self addSubview:_separator];

        [self button:@"minus.magnifyingglass" tag:6 label:@"Zoom out" circle:YES];
        [self button:@"plus.magnifyingglass" tag:8 label:@"Zoom in" circle:YES];

        _zoomLabel = [UILabel new];
        _zoomLabel.text = @"1.00x";
        _zoomLabel.textAlignment = NSTextAlignmentCenter;
        _zoomLabel.textColor = UIColor.whiteColor;
        [self addSubview:_zoomLabel];

        UIButton *mirror = [self button:@"arrow.left.and.right" tag:11 label:@"Mirror" circle:YES];
        mirror.tintColor = [UIColor colorWithRed:.20 green:.67 blue:.79 alpha:1];
        mirror.backgroundColor = [mirror.tintColor colorWithAlphaComponent:.1];
        mirror.layer.borderColor = [mirror.tintColor colorWithAlphaComponent:.28].CGColor;
    }
    return self;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(194, 238); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = MIN(self.bounds.size.width / 194, self.bounds.size.height / 238);
    if (s <= 0) return;
    CGFloat x = (self.bounds.size.width - 194 * s) / 2;
    CGFloat y = (self.bounds.size.height - 238 * s) / 2;

    _title.frame = CGRectMake(x + 12 * s, y + 10 * s, 117 * s, 20 * s);
    _title.font = [UIFont boldSystemFontOfSize:13 * s];

    _buttons[@10].frame = CGRectMake(x + 130 * s, y + 7 * s, 26 * s, 26 * s);
    _buttons[@12].frame = CGRectMake(x + 163 * s, y + 7 * s, 26 * s, 26 * s);

    NSDictionary *positions = @{
        @1: @[@80, @37], @2: @[@40, @74], @9: @[@80, @74],
        @4: @[@120, @74], @5: @[@80, @111],
        @6: @[@21, @159], @8: @[@139, @159], @11: @[@80, @200]
    };
    for (NSNumber *tag in positions) {
        NSArray *p = positions[tag];
        UIButton *b = _buttons[tag];
        b.frame = CGRectMake(x + [p[0] doubleValue] * s, y + [p[1] doubleValue] * s, 34 * s, 34 * s);
        b.layer.cornerRadius = 17 * s;
    }
    for (NSNumber *tag in _buttons) {
        UIButton *b = _buttons[tag];
        CGFloat size = (tag.integerValue == 6 || tag.integerValue == 8) ? 19 * s : 22 * s;
        [b setPreferredSymbolConfiguration:
         [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightRegular]
                          forImageInState:UIControlStateNormal];
    }
    _separator.frame = CGRectMake(x + 12 * s, y + 149 * s, 170 * s, MAX(.5, .5 * s));
    _zoomLabel.frame = CGRectMake(x + 59 * s, y + 161 * s, 76 * s, 30 * s);
    _zoomLabel.font = [UIFont boldSystemFontOfSize:14 * s];
}

- (void)applySettings:(NSDictionary *)settings {
    _zoomLabel.text = [NSString stringWithFormat:@"%.2fx", [settings[@"Zoom"] doubleValue]];
    _buttons[@11].accessibilityValue = [settings[@"Mirror"] boolValue] ? @"ON" : @"OFF";
}

- (void)refresh {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *s = VCFReadSettings(NULL);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applySettings:s]; });
    });
}

- (void)close { if (self.didClose) self.didClose(); }

- (void)adjust:(UIButton *)sender {
    if (_busy) return;
    _busy = YES;
    NSInteger tag = sender.tag;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        VCFUpdateSettings(^(NSMutableDictionary *s) {
            double x = [s[@"X"] doubleValue];
            double y = [s[@"Y"] doubleValue];
            double zoom = [s[@"Zoom"] doubleValue];
            switch (tag) {
                case 1: y -= .08; break;
                case 2: x -= .08; break;
                case 3: x = 0; y = 0; break;
                case 4: x += .08; break;
                case 5: y += .08; break;
                case 6: zoom /= 1.1; break;
                case 8: zoom *= 1.1; break;
                case 9: s[@"Rotation"] = @(([s[@"Rotation"] intValue] + 90) % 360); break;
                case 10: x = 0; y = 0; zoom = 1; s[@"Rotation"] = @0; s[@"Mirror"] = @NO; break;
                case 11: s[@"Mirror"] = @(![s[@"Mirror"] boolValue]); break;
            }
            s[@"X"] = @(x); s[@"Y"] = @(y); s[@"Zoom"] = @(zoom);
        }, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            _busy = NO;
            [self refresh];
            _title.text = error ? @"Save error" : @"Camera control";
            _title.textColor = error ? UIColor.systemRedColor : UIColor.whiteColor;
            if (self.didChange) self.didChange(error);
        });
    });
}
@end
