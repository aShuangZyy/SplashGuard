#import <UIKit/UIKit.h>

@interface SGRootVC : UIViewController
@end

@implementation SGRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:@"OBJC MINI OK"];
    [lines addObject:[NSString stringWithFormat:@"iOS %@", [[UIDevice currentDevice] systemVersion]]];
    [lines addObject:[NSString stringWithFormat:@"bundle %@", [[NSBundle mainBundle] bundleIdentifier]]];
    [lines addObject:[NSString stringWithFormat:@"home %@", NSHomeDirectory()]];

    NSString *probe = [NSHomeDirectory() stringByAppendingPathComponent:@"sgprobe_objc.txt"];
    NSError *err = nil;
    BOOL wrote = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&err];
    [lines addObject:wrote ? @"write OK" : [NSString stringWithFormat:@"write FAIL %@", err.localizedDescription]];

    UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:15];
    label.text = [lines componentsJoinedByString:@"\n"];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:label];
}

@end

@interface SGObjCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGObjCAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[SGRootVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SGObjCAppDelegate class]));
    }
}
