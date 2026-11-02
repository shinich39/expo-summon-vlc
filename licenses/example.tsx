
import {
  Linking,
  Platform,
  Pressable,
  ScrollView,
  Text,
  View,
} from 'react-native';

const vlc =
  Platform.OS === 'ios'
    ? {
        name: 'VLCKit',
        version: '4.0.0a25',
        license: 'LGPL-2.1-or-later',
        source: 'https://code.videolan.org/videolan/VLCKit',
      }
    : {
        name: 'LibVLC',
        version: '3.7.7',
        license: 'LGPL-2.1',
        source: 'https://code.videolan.org/videolan/libvlcjni',
      };

export default function LicensesView() {
  return (
    <ScrollView contentContainerStyle={{ padding: 16 }}>
      <Text>{vlc.name}</Text>
      <Text>Version: {vlc.version}</Text>
      <Text>License: {vlc.license}</Text>
      <Text>Copyright © VideoLAN and contributors</Text>

      <Pressable onPress={() => void Linking.openURL(vlc.source)}>
        <Text>Source Code</Text>
      </Pressable>

      <View style={{ height: 16 }} />

      <Pressable
        onPress={() =>
          void Linking.openURL(
            'https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html'
          )
        }
      >
        <Text>GNU LGPL 2.1 License</Text>
      </Pressable>
    </ScrollView>
  );
}
