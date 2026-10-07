function showBootstrapError() {
  const status = document.getElementById("secure-ticket-bootstrap-status");
  const error = document.getElementById("secure-ticket-bootstrap-error");
  if (status) status.classList.add("hidden");
  if (error) {
    error.hidden = false;
    error.classList.remove("hidden");
  }
}

function runSecureTicketBootstrap() {
  if (window.location.pathname !== "/t") {
    return;
  }

  const rawHash = window.location.hash;
  const fragment = rawHash.startsWith("#") ? rawHash.slice(1) : rawHash;
  window.history.replaceState(null, "", window.location.pathname + window.location.search);

  if (!fragment || fragment.length < 8) {
    showBootstrapError();
    return;
  }

  const deliveryToken = fragment;
  const csrfMeta = document.querySelector("meta[name='csrf-token']");
  const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : null;

  if (!csrfToken) {
    showBootstrapError();
    return;
  }

  const body = new URLSearchParams();
  body.set("delivery_token", deliveryToken);

  fetch("/t/session", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "x-csrf-token": csrfToken,
      Accept: "application/json",
    },
    body: body.toString(),
  })
    .then((response) => {
      if (!response.ok) {
        showBootstrapError();
        return null;
      }
      return response.json();
    })
    .then((data) => {
      if (data && typeof data.redirect_to === "string" && data.redirect_to.startsWith("/t/view/")) {
        window.location.replace(data.redirect_to);
      } else {
        showBootstrapError();
      }
    })
    .catch(() => {
      showBootstrapError();
    });
}

runSecureTicketBootstrap();
