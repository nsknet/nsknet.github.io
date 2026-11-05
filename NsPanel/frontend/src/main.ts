import { createPinia } from 'pinia';
import { createApp } from 'vue';

// Fonts are bundled, not fetched from Google: the panel is often reached over an
// SSH tunnel from a LAN box with no internet, and admin visits should not leak.
import '@fontsource/geist-sans/400.css';
import '@fontsource/geist-sans/500.css';
import '@fontsource/geist-sans/600.css';
import '@fontsource/geist-sans/700.css';
import '@fontsource/geist-mono/400.css';
import '@fontsource/geist-mono/500.css';

import App from './App.vue';
import './assets/main.css';
import { loadRouteData } from './composables/useScreenData';
import { START_LOCATION } from 'vue-router';

import { router } from './router';

const app = createApp(App);
app.use(createPinia());
app.use(router);

// Screens declare what they need in their route meta. The load is fired after
// navigation, never awaited: a slow probe must not freeze the UI on the old
// screen — every view renders its own loading state meanwhile.
//
// A query-only change (a filter mirrored into the URL) stays on the same screen
// and must not refetch everything on each keystroke.
router.afterEach((to, from, failure) => {
  if (failure) return;
  if (from !== START_LOCATION && to.path === from.path) return;
  void loadRouteData(to.meta.loads);
});

app.mount('#app');
