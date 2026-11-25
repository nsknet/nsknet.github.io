/** NsPanel's own systemd service: install state, version and the update check. */
import { defineStore } from "pinia";

import { endpoints, fetchData, postAction } from "@/api/client";
import type { DataResponse, PanelServiceStatus } from "@/api/types";

import { createResource } from "./resource";

const EMPTY: PanelServiceStatus = {
  installed: false,
  active: "inactive",
  enabled: "disabled",
  port: 7778,
  tls: true,
  branch: "main",
  repo_url: "",
  repo_dir: "",
  release_dir: null,
  subnets: [],
  urls: [],
  installed_commit: null,
  running_commit: null,
  previous_commit: null,
  can_rollback: false,
  last_rollback: null,
  installed_at: null,
  updated_at: null,
  update: null,
  is_self: false,
  current_port: 0,
  default_port: 7778,
  subnet_choices: [],
};

export const usePanelStore = defineStore("panel", () => {
  const status = createResource<PanelServiceStatus>(EMPTY, () =>
    fetchData<PanelServiceStatus>(endpoints.panel),
  );

  /** `git fetch` on the server, then the refreshed status. Throws ApiError. */
  async function checkUpdates(): Promise<void> {
    const body = await postAction<DataResponse<PanelServiceStatus>>(
      `${endpoints.panel}/check`,
    );
    status.data.value = body.data;
  }

  return {
    status: status.data,
    loading: status.loading,
    loaded: status.loaded,
    error: status.error,
    load: status.load,
    checkUpdates,
  };
});
