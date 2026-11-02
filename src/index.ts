// Reexport the native module. On web, it will be resolved to ExpoSummonVlcModule.web.ts
// and on native platforms to ExpoSummonVlcModule.ts
export { default } from './ExpoSummonVlcModule';
export * from './ExpoSummonVlc.types';
export { PlayerView } from './PlayerView';
