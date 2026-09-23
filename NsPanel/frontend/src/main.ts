import { createPinia } from 'pinia';
import { createApp } from 'vue';

import App from './App.vue';
import './assets/main.css';
import { loadRouteData } from './composables/useScreenData';
import { router } from './router';

const app = createApp(App);
app.use(createPinia());
app.use(router);

// Screens declare what they need in their route meta. The load is fired after
// navigation, never awaited: a slow probe must not freeze the UI on the old
// screen — every view renders its own loading state meanwhile.
router.afterEach((to) => {
  void loadRouteData(to.meta.loads);
});

app.mount('#app');
