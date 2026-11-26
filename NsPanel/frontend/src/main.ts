import { createPinia } from 'pinia';
import { createApp } from 'vue';

// Fonts are bundled, not fetched from Google: the panel is often reached over an
// SSH tunnel from a LAN box with no internet, and admin visits should not leak.
import './assets/fonts.css';

import App from './App.vue';
import './assets/main.css';
import { loadRouteData } from './composables/useScreenData';
import { START_LOCATION } from 'vue-router';

import { router } from './router';
import { useAuthStore } from './stores/auth';

const app = createApp(App);
app.use(createPinia());
app.use(router);
const auth = useAuthStore();

// Screens declare what they need in their route meta. The load is fired after
// navigation, never awaited: a slow probe must not freeze the UI on the old
// screen — every view renders its own loading state meanwhile.
//
// A query-only change (a filter mirrored into the URL) stays on the same screen
// and must not refetch everything on each keystroke.
router.afterEach((to, from, failure) => {
  if (failure) return;
  if (from !== START_LOCATION && to.path === from.path) return;
  // Before sign-in there is nothing to load; App.vue loads the route after login.
  if (auth.status !== 'signed-in') return;
  void loadRouteData(to.meta.loads);
});

app.mount('#app');
