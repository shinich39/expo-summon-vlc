const { AndroidConfig, withAndroidManifest } = require('expo/config-plugins');

module.exports = function withSummonVlc(config) {
  return withAndroidManifest(config, (config) => {
    const activity = AndroidConfig.Manifest.getMainActivityOrThrow(config.modResults);
    activity.$['android:supportsPictureInPicture'] = 'true';
    const changes = new Set((activity.$['android:configChanges'] || '').split('|').filter(Boolean));
    for (const value of ['orientation', 'screenSize', 'smallestScreenSize', 'screenLayout']) changes.add(value);
    activity.$['android:configChanges'] = [...changes].join('|');
    return config;
  });
};
