import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import VaultController from "./hooks/controller";

const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
if (csrf && document.querySelector("[data-phx-main]")) {
  const liveSocket = new LiveSocket("/live", Socket, {
    params: { _csrf_token: csrf },
    hooks: { VaultController },
  });
  liveSocket.connect();
}
