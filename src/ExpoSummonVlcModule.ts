import { NativeModule, requireNativeModule } from 'expo';

declare class ExpoSummonVlcModule extends NativeModule<{}> {}

export default requireNativeModule<ExpoSummonVlcModule>('ExpoSummonVlc');
