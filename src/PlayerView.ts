import { requireNativeView } from 'expo';
import type { PlayerViewProps } from './ExpoSummonVlc.types';

export const PlayerView = requireNativeView<PlayerViewProps>('ExpoSummonVlc');
