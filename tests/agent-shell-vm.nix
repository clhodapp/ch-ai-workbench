# SPDX-License-Identifier: MIT
#
# A graphical Emacs, with this layer and the editor configured by Home
# Manager, opens an OpenCode session in agent-shell inside an enrolled
# checkout. OpenCode runs whole inside the checkout's sandbox under the
# real srt, and talks to a mock model API that answers with a call to
# the tool list-buffers of the Emacs MCP server. The call crosses the
# sandbox through the socket agent-sandbox serves the bridge on, and
# reaches the Emacs on the screen: the tool result the mock receives
# holds that Emacs's buffer names.
#
# A terminal in the same session runs a command through `agent-sandbox
# run`, which gives it a pseudo-terminal of its own; resizing the
# terminal must reach the command inside the sandbox.
{
  pkgs,
  lib,
  self,
  home-manager,
  homeModules,
  llmAgents,
}:
let
  mockPort = 18799;
  mockBase = "http://127.0.0.2:${toString mockPort}/v1";
in
pkgs.testers.runNixOSTest {
  name = "agent-shell-vm";

  nodes.machine =
    { ... }:
    {
      imports = [
        "${pkgs.path}/nixos/tests/common/user-account.nix"
        "${pkgs.path}/nixos/tests/common/x11.nix"
        home-manager.nixosModules.home-manager
      ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 4;
      test-support.displayManager.auto.user = "alice";
      environment.systemPackages = [ pkgs.tmux ];

      systemd.services.mock-inference = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${self}/tests/agent-sandbox/mock-inference.py 127.0.0.2 ${toString mockPort} /tmp/requests.jsonl list-buffers";
      };

      home-manager.useGlobalPkgs = true;
      home-manager.users.alice = {
        imports = homeModules;
        home.stateVersion = "25.05";
        programs.emacs.enable = true;
        programs.git.enable = true;
        ch-emacs-config.emacs.enable = true;
        # The test starts the Emacs daemon itself, on the X display. The
        # managed daemon rotates at activation, which at boot runs before
        # the runtime directory of the user exists.
        ch-emacs-config.emacs.bundles.daemon.enable = false;
        ch-ai-workbench = {
          emacs.enable = true;
          claude.enable = true;
          claude-code.enable = true;
          emacs-integration.enable = true;
          agent-sandbox = {
            enable = true;
            runtime.claudePackage = pkgs.hello;
            runtime.sandboxRuntimePackage = llmAgents.sandbox-runtime;
            modules.mock = {
              description = "the mock model API";
              allowedDomains = [ "127.0.0.2:${toString mockPort}" ];
            };
          };
          opencode = {
            enable = true;
            package = llmAgents.opencode;
            providers = lib.mkForce { };
            settings = {
              model = "mock/mock-model";
              provider.mock = {
                npm = "@ai-sdk/openai-compatible";
                name = "mock";
                options = {
                  baseURL = mockBase;
                  apiKey = "mock";
                };
                models.mock-model.name = "mock-model";
              };
            };
          };
        };
        home.sessionVariables.OPENCODE_DISABLE_MODELS_FETCH = "1";
      };
    };

  testScript = ''
    import shlex

    def alice(command):
        return machine.succeed("su - alice -c " + shlex.quote(command))

    def elisp(form):
        return alice("emacsclient --eval " + shlex.quote(form)).strip()

    machine.wait_for_x()
    machine.wait_for_unit("mock-inference.service")
    try:
        machine.wait_for_unit("home-manager-alice.service")
    except Exception:
        print(machine.execute("journalctl -u home-manager-alice.service --no-pager | tail -80")[1])
        raise

    alice("git init -q repo && agent-sandbox enroll mock -C repo --quiet")

    with subtest("a resize reaches a command inside the sandbox"):
        alice(
            "tmux new-session -d -s relay -x 80 -y 24 -c ~/repo "
            + shlex.quote(
                "agent-sandbox run opencode -- sh -c "
                "'stty size; trap \"stty size\" WINCH; while :; do sleep 0.2; done'"
            )
        )
        machine.wait_until_succeeds(
            "su - alice -c 'tmux capture-pane -p -t relay' | grep -qx '24 80'", timeout=60
        )
        alice("tmux resize-window -t relay -x 100 -y 30")
        machine.wait_until_succeeds(
            "su - alice -c 'tmux capture-pane -p -t relay' | grep -qx '30 100'", timeout=30
        )
        alice("tmux kill-server")

    with subtest("agent-shell drives OpenCode in the sandbox, which calls back into Emacs"):
        machine.succeed(
            "su - alice -c 'DISPLAY=:0 emacs --fg-daemon=server > /tmp/emacs.log 2>&1 &'"
        )
        machine.wait_until_succeeds("su - alice -c 'emacsclient --eval t'", timeout=300)
        alice("DISPLAY=:0 emacsclient -n -c")
        # A new session each time: the default asks in the minibuffer
        # which session to resume.
        elisp("(progn (setq acp-logging-enabled t agent-shell-session-strategy (quote new)) t)")
        elisp(
            '(let ((default-directory (expand-file-name "~/repo/")))'
            "  (agent-shell-start :config (agent-shell-opencode-make-agent-config)) t)"
        )
        shell = (
            '(seq-find (lambda (b) (with-current-buffer b (derived-mode-p (quote agent-shell-mode))))'
            " (buffer-list))"
        )

        def acp_logs():
            print(elisp(
                "(mapconcat (lambda (b) (with-current-buffer b (concat \"== \" (buffer-name) \"\\n\""
                " (buffer-substring-no-properties (max (point-min) (- (point-max) 4000)) (point-max)))))"
                ' (seq-filter (lambda (b) (string-match-p "acp" (buffer-name b))) (buffer-list)) "\\n")'
            ))

        # The session is ready once OpenCode has answered session/new.
        try:
            machine.wait_until_succeeds(
                "su - alice -c " + shlex.quote(
                    "emacsclient --eval '(with-current-buffer " + shell
                    + " (map-elt (map-elt (agent-shell--state) :session) :id))' | grep -v -x nil"
                ),
                timeout=120,
            )
        except Exception:
            acp_logs()
            raise
        elisp(
            '(progn (agent-shell-insert :text "List the buffers." :submit t'
            " :shell-buffer " + shell + ") t)"
        )
        try:
            machine.wait_until_succeeds(
                "grep -q 'scratch' /tmp/requests.jsonl && grep -q '\"role\": \"tool\"' /tmp/requests.jsonl",
                timeout=180,
            )
        except Exception:
            print(machine.execute("cut -c1-3000 /tmp/requests.jsonl")[1])
            print(machine.execute("su - alice -c " + shlex.quote(
                "emacsclient --eval '(with-current-buffer " + shell
                + " (buffer-substring-no-properties (max (point-min) (- (point-max) 3000)) (point-max)))'"))[1])
            acp_logs()
            raise
        machine.wait_until_succeeds(
            "su - alice -c "
            + shlex.quote(
                "emacsclient --eval '(with-current-buffer " + shell + " (buffer-string))' | grep -q done"
            ),
            timeout=60,
        )
        machine.screenshot("agent-shell")
  '';
}
