<script setup lang="ts">
/** The sign-in screen, shown by the shell whenever there is no session. */
import { onMounted, ref } from 'vue';

import Btn from '@/components/ui/Btn.vue';
import LIcon from '@/components/ui/LIcon.vue';
import Spinner from '@/components/ui/Spinner.vue';
import { ApiError } from '@/api/client';
import { useAuthStore } from '@/stores/auth';

const auth = useAuthStore();

const username = ref('admin');
const password = ref('');
const showPassword = ref(false);
const pending = ref(false);
const error = ref('');
const passwordEl = ref<HTMLInputElement | null>(null);

onMounted(() => passwordEl.value?.focus());

async function submit(event: Event): Promise<void> {
  event.preventDefault();
  if (pending.value) return;
  if (!username.value.trim() || !password.value) {
    error.value = 'Enter the username and password.';
    return;
  }
  pending.value = true;
  error.value = '';
  try {
    await auth.login(username.value.trim(), password.value);
    password.value = '';
  } catch (err) {
    error.value = err instanceof ApiError ? err.message : 'Could not reach the panel. Check the connection.';
    password.value = '';
    passwordEl.value?.focus();
  } finally {
    pending.value = false;
  }
}
</script>

<template>
  <main class="min-h-screen grid place-items-center bg-c-canvas px-4 py-10">
    <div class="w-full max-w-[380px]">
      <div class="flex flex-col items-center mb-6">
        <div
          class="w-12 h-12 rounded-theme-lg brand-mark text-white grid place-items-center font-bold text-lg tracking-[-0.04em] shadow-sm ring-1 ring-inset ring-white/15"
          aria-hidden="true"
        >
          N
        </div>
        <h1 class="mt-3 mb-0 text-lg font-semibold tracking-[-0.02em] text-c-tx">Sign in to NsPanel</h1>
      </div>

      <form
        class="bg-c-card border border-c-border rounded-theme-lg shadow-card p-5 flex flex-col gap-4"
        novalidate
        @submit="submit"
      >
        <p
          v-if="auth.expired"
          class="m-0 text-sm-var text-c-tx2 bg-c-infosoft border border-c-border rounded-lg px-3 py-2"
          role="status"
        >
          Your session ended. Sign in again to continue.
        </p>

        <div class="flex flex-col gap-1.5">
          <label for="login-username" class="text-sm-var font-medium text-c-tx">Username</label>
          <input
            id="login-username"
            v-model="username"
            class="input"
            name="username"
            autocomplete="username"
            autocapitalize="off"
            spellcheck="false"
            required
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label for="login-password" class="text-sm-var font-medium text-c-tx">Password</label>
          <div class="relative">
            <input
              id="login-password"
              ref="passwordEl"
              v-model="password"
              class="input w-full pr-10"
              name="password"
              :type="showPassword ? 'text' : 'password'"
              autocomplete="current-password"
              required
              :aria-invalid="!!error"
              aria-describedby="login-error"
            />
            <button
              type="button"
              class="absolute right-1 top-1/2 -translate-y-1/2 w-8 h-8 grid place-items-center rounded-md text-c-tx3 hover:text-c-tx hover:bg-c-hover"
              :aria-label="showPassword ? 'Hide password' : 'Show password'"
              @click="showPassword = !showPassword"
            >
              <LIcon is="width:16px;height:16px" :name="showPassword ? 'eye-off' : 'eye'" />
            </button>
          </div>
        </div>

        <p
          id="login-error"
          class="m-0 min-h-[1.25rem] text-sm-var text-c-danger"
          role="alert"
          aria-live="assertive"
        >
          {{ error }}
        </p>

        <Btn variant="primary" type="submit" :disabled="pending">
          <Spinner v-if="pending" label="" />
          <LIcon v-else name="lock" />
          {{ pending ? 'Signing in…' : 'Sign in' }}
        </Btn>
      </form>

      <p class="mt-4 text-center text-xs-var text-c-tx3">
        Forgot the password? On the server run
        <code class="mono">sudo ./run.sh --reset-password</code>
      </p>
    </div>
  </main>
</template>
