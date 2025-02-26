import React from 'react';
import { createDevApp } from '@backstage/dev-utils';
import { mftWrapperPlugin, MftWrapperPage } from '../src/plugin';

createDevApp()
  .registerPlugin(mftWrapperPlugin)
  .addPage({
    element: <MftWrapperPage />,
    title: 'Root Page',
    path: '/mft-wrapper',
  })
  .render();
