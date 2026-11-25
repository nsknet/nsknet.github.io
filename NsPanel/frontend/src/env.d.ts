/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue';

  const component: DefineComponent<{}, {}, any>;
  export default component;
}

/** package.json version, injected by vite.config.ts. */
declare const __APP_VERSION__: string;
/** Last commit touching frontend/ when this bundle was built (may be empty). */
declare const __FRONTEND_COMMIT__: string;
