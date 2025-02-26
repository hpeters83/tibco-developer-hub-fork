import {
  createPlugin,
  createRoutableExtension,
} from '@backstage/core-plugin-api';

import { rootRouteRef } from './routes';

export const mftWrapperPlugin = createPlugin({
  id: 'mft-wrapper',
  routes: {
    root: rootRouteRef,
  },
});

export const MftWrapperPage = mftWrapperPlugin.provide(
  createRoutableExtension({
    name: 'MftWrapperPage',
    component: () =>
      import('./components/MFTUiWrapper/MFTUiWrapper').then(m => m.MFTUiWrapper),
    mountPoint: rootRouteRef,
  }),
);
