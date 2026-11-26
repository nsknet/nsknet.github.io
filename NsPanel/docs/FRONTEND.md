# Frontend guide

How screens in `frontend/src` are built. Read this before adding or changing a view.

## Layout and navigation

- `router/index.ts` is the only route table. A route's `meta` gives its nav entry
  (`nav`), breadcrumbs (`crumbs`), the stores it needs (`loads`) and the nav item to
  highlight (`rail`). The shell (`App.vue`, `components/NavRail.vue`) renders from it.
- Sections: **Overview**, **Apps** (sites and services together), **Tools**,
  **Network** (Firewall, DNS, Interfaces), **System** (Host, Storage, Processes),
  **Activity** (Jobs, Audit log), **Settings** (Panel service, Security).
- Views live in `views/<section>/`. A screen starts with `<PageHeader>` (title,
  one-line subtitle, actions on the right) and is made of `<Card>`s.
- Below `md` the rail becomes a drawer. Every screen must work at 375 px wide: grids
  collapse to one column (`grid-cols-1 md:grid-cols-2`), tables scroll inside their
  card (`DataTable` does this), button rows wrap.

## Data

- Screens never fetch on mount: the route's `meta.loads` loads the stores, and the
  same loaders run again after any job finishes (`jobsStore.onJobFinished`).
- Stores are built with `createResource` (`stores/resource.ts`): each exposes `data`,
  `loading`, `loaded` and **`error`**. Render all four states:
  - loading and not loaded → skeletons (`Skeleton`, or `DataTable`'s built-in rows);
  - `error` and nothing loaded → `<ErrorState :message="error" @retry="load()" />`;
  - loaded and empty → `<EmptyState>` with what to do next;
  - otherwise the data. Never show "nothing here" when the load failed.
- Background refresh: `usePolling(() => store.load({ silent: true }), ms)` — it pauses
  while the tab is hidden and never overlaps. Silent loads raise no toast.
- Refresh buttons: `const { refresh, refreshing } = useRefresh()` and
  `<Btn :loading="refreshing" @click="refresh">`. No "refreshed" toast.
- Build API paths with `apiPath` from `utils/format.ts`, which URL-encodes every part:
  ``apiPath`/api/v1/services/${name}/start` ``.

## Actions

- Every action that changes the server goes through `useJobRunner().run(path, fields,
  { title, onSuccess })`: POST, then the live output dialog. Use `onSuccess` for
  navigation after create/delete — it does not run when the job fails.
- Synchronous actions (`MessageResponse`) toast their message through the same runner.
- **Confirmation.** `ui.confirmThen(title, body, onYes, options)`:
  - anything that deletes, stops, disables or overwrites: `{ danger: true,
    confirmLabel: 'Delete rule' }` — the button says the verb, never "Continue";
  - anything that cannot be undone or can cut off access (format a disk, delete a
    firewall rule for SSH or the panel's port, disable the firewall): also
    `typeToConfirm: '<the name>'`, and `details: [...]` listing what is affected.

## Forms

- Copy the pattern: each input inside `<Field label error help v-slot="f">`, bound with
  `:id="f.id" :aria-describedby="f.describedBy" :aria-invalid="f.invalid"`.
- Validate inline with `utils/validate.ts` (mirrors the backend rules). Show the error
  under the field once it was touched or on submit — not in a toast.
- Submit: disable the button while the request is pending (`<Btn :loading>`), keep the
  form (and the dialog) open on failure, close only on success.
- Passwords: `<PasswordField>` (hidden by default, optional Generate/Copy).
- Firewall scope: `<SubnetPicker v-model="selected" :allow-public>`.

## Dialogs

- Every dialog is a `<BaseDialog title … @close>` with content in the default slot and
  buttons in `#footer`. It handles focus, Escape (top dialog only), the backdrop and
  `role="dialog"`. Pass `:dirty="true"` when closing would lose typed input, and
  `:closable="false"` while a request runs. Mark the field to focus with
  `data-autofocus`.
- Do not add `document.addEventListener('keydown', …)` in views.

## Components (`components/ui/`)

| Component | Use |
|---|---|
| `Btn` | Every button. `variant` default/primary/ghost/danger/danger-solid/success/warn/info, `sm`, `square`, `loading`, `type` (defaults to `button`). |
| `Card`, `CardHeader` | Surfaces; `CardHeader title icon` + actions slot. |
| `PageHeader` | Screen title row. |
| `DataTable` | Lists: `columns` (`Column` in `types.ts`), `rows`, `row-key`, `label`, `loading`, `error`, `@retry`, `row-to` (rows become links), `#cell-<key>` slots, sortable columns, empty slot. |
| `KeyValueList` | Label/value details; `#value-<key>` slots; `copy` per item. |
| `Tabs` | `v-model` + `items` (`TabItem`); panel in the default slot. |
| `FilterPills` | Single-choice filter. Mirror it in the URL with `useQueryRef`. |
| `Field`, `PasswordField`, `SubnetPicker` | Forms (see above). Plain inputs use `class="input"`; selects `class="input"` on `<select>`. |
| `Alert` | Inline callout: `tone` info/ok/warn/danger, `title`, `#action`. |
| `ErrorState`, `EmptyState`, `Skeleton`, `Spinner` | States. |
| `MetricCard` | Usage tile with a bar coloured by percentage. |
| `Badge`, `StatusBadge`, `TypeChip`, `ToolLogo`, `LIcon` | Small pieces. Icons by kebab name; add new ones to `icons.ts`. |

## Style

- Colours only through tokens (`bg-c-card`, `text-c-tx2`, `border-c-border`,
  `text-c-danger`, `bg-c-warnsoft`, …; see `assets/main.css`). No hex values in views.
- Type scale: `text-base-var`, `text-sm-var`, `text-xs-var`; nothing smaller than
  `text-2xs-var` (12 px). Secondary text is `text-c-tx2`; `text-c-tx3` only for
  hints and placeholders.
- Numbers in tables and tiles: `tabular-nums`. Paths, ports, IDs, hashes: `mono`.
- Clickable things are `<button>`, `<RouterLink>` or `<a href>` — never a `div` or
  `tr` with `@click` alone.
