const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

// Expo's scene delegate owns the window and starts the React Native factory.
module.exports = function withSceneLifecycle(config) {
  config = withInfoPlist(config, (config) => {
    config.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [{
          UISceneConfigurationName: 'Default Configuration',
          UISceneDelegateClassName: 'EXExpoAppSceneDelegate',
        }],
      },
    };
    return config;
  });

  return withAppDelegate(config, (config) => {
    if (config.modResults.language !== 'swift') {
      throw new Error('Scene lifecycle configuration requires the Expo Swift AppDelegate.');
    }
    let source = config.modResults.contents;
    if (!source.includes('ExpoReactNativeFactoryProvider')) {
      const declaration = 'class AppDelegate: ExpoAppDelegate {';
      if (!source.includes(declaration)) throw new Error('Unable to find the Expo AppDelegate declaration.');
      source = source.replace(declaration, 'class AppDelegate: ExpoAppDelegate, ExpoReactNativeFactoryProvider {');
    }
    const startup = /#if os\(iOS\) \|\| os\(tvOS\)\s*window = UIWindow\(frame: UIScreen\.main\.bounds\)\s*factory\.startReactNative\([\s\S]*?launchOptions: launchOptions\)\s*#endif/;
    if (source.includes('factory.startReactNative(')) {
      if (!startup.test(source)) throw new Error('Unable to safely migrate the Expo window startup code.');
      source = source.replace(startup, '// ExpoAppSceneDelegate creates the window and starts React Native.');
    }
    config.modResults.contents = source;
    return config;
  });
};
