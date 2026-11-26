/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue';

  const component: DefineComponent<object, object, unknown>;
  export default component;
}

/** package.json version, injected by vite.config.ts. */
declare const __APP_VERSION__: string;
