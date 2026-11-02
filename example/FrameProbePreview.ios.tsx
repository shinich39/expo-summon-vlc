import { requireNativeView } from 'expo';
import type { StyleProp, ViewStyle } from 'react-native';

export default requireNativeView<{ style?: StyleProp<ViewStyle> }>('ExpoSummonVlcProbe');
