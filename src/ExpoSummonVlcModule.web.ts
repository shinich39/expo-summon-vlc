import { registerWebModule, NativeModule } from 'expo';

// ExpoSummonVlcModule is not available on the web platform.
class ExpoSummonVlcModule extends NativeModule<{}> {}

export default registerWebModule(ExpoSummonVlcModule, 'ExpoSummonVlcModule');
