# SPDX-License-Identifier: MIT
# Real Secret Service and gh, with disposable credentials and a VM-local GitHub.
{ pkgs, lib, self, home-manager, llmAgents }:
let
  certificates = pkgs.runCommand "github-keyring-vm-certificate" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj /CN=api.github.com \
      -addext 'subjectAltName=DNS:api.github.com,DNS:github.com' \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -keyout "$out/key.pem" -out "$out/cert.pem"
  '';
  sandbox = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-sandbox;
in
pkgs.testers.runNixOSTest {
  name = "github-keyring-sandbox";
  nodes.machine = { ... }: {
    imports = [ home-manager.nixosModules.home-manager ];
    # Match the workstation: pathname-scoped Unix sockets require Landlock ABI 9.
    boot.kernelPackages = pkgs.linuxPackages_latest;
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    users.users.alice = { isNormalUser = true; uid = 1000; linger = true; };
    services.dbus.enable = true;
    services.dbus.packages = [ pkgs.gnome-keyring ];
    security.pki.certificateFiles = [ "${certificates}/cert.pem" ];
    networking.extraHosts = ''
      127.0.0.2 api.github.com github.com
    '';
    environment.systemPackages = [ pkgs.curl pkgs.libsecret pkgs.python3 pkgs.git ];
    systemd.services.fake-github = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${self}/tests/agent-sandbox/github-api-fixture.py ${certificates}/cert.pem ${certificates}/key.pem";
    };
    systemd.services.mock-inference = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${self}/tests/agent-sandbox/mock-inference.py 127.0.0.3 18799 /tmp/model-requests.jsonl";
    };
    home-manager.useGlobalPkgs = true;
    home-manager.users.alice = {
      imports = [ self.modules.homeManager.agent-sandbox self.modules.homeManager.codex ];
      home.stateVersion = "25.05";
      programs.git.enable = true;
      home.file.".config/gh/hosts.yml".text = ''
        github.com:
            user: vm-alice
            git_protocol: https
            users:
                vm-alice: {}
      '';
      systemd.user.services.vm-keyring = {
        Unit.Description = "Disposable Secret Service for the credential route test";
        Service = {
          ExecStart = "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --foreground --components=secrets --unlock";
          StandardInput = "data";
          StandardInputText = "vm-keyring-password";
          Environment = "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus";
        };
        Install.WantedBy = [ "default.target" ];
      };
      ch-ai-workbench.agent-sandbox = {
        enable = true;
        emacsMcpCommand = [ ];
        runtime.claudePackage = pkgs.hello;
        runtime.sandboxRuntimePackage = llmAgents.sandbox-runtime;
        trustedExecutables.github-auth-token.environment.DBUS_SESSION_BUS_ADDRESS = "";
        modules = {
          vm-runtime = {
            toolset = [ pkgs.python3 pkgs.git ];
            allowedDomains = [ "127.0.0.3" ];
            allowLocalBinding = true;
          };
          github = {
            toolset = [ pkgs.gh ];
            githubKeyring = true;
            allowedDomains = [ "github.com" "api.github.com" ];
          };
          bare-gh = {
            toolset = [ pkgs.gh ];
            allowedDomains = [ "github.com" "api.github.com" ];
          };
        };
      };
      ch-ai-workbench.codex = {
        enable = true;
        package = llmAgents.codex;
        settings = {
          model = "mock-model";
          model_provider = "mock";
          approval_policy = "never";
          model_providers.mock = {
            name = "VM mock";
            base_url = "http://127.0.0.3:18799/v1";
            env_key = "MOCK_API_KEY";
            wire_api = "responses";
          };
        };
      };
    };
  };
  testScript = ''
    import shlex

    def alice(command):
        environment = (
            "export XDG_RUNTIME_DIR=/run/user/1000 "
            "XDG_CONFIG_HOME=/home/alice/.config "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
            "MOCK_API_KEY=mock; "
        )
        return machine.succeed("su - alice -c " + shlex.quote(environment + command))

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("home-manager-alice.service")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("fake-github.service")
    machine.wait_for_unit("mock-inference.service")
    machine.wait_until_succeeds("test -S /run/user/1000/bus")
    alice("systemctl --user start vm-keyring.service agent-sandbox-trusted-github-auth-token.socket")
    machine.wait_until_succeeds("curl -sS https://api.github.com/user >/dev/null")
    with subtest("host gh reads the real Secret Service, not hosts.yml plaintext"):
        alice("printf ghp_vm_keyring_fixture | ${pkgs.libsecret}/bin/secret-tool store --label=github-vm service gh:github.com username vm-alice")
        alice("test \"$(${lib.getExe pkgs.gh} auth token --hostname github.com)\" = ghp_vm_keyring_fixture")
        alice("! grep -q oauth_token ~/.config/gh/hosts.yml")
    with subtest("cached Codex environment is repaired and the other clone stays denied"):
        try:
            result = alice(
                "PYTHONPATH=${sandbox}/${pkgs.python3.sitePackages} "
                "${lib.getExe pkgs.python3} ${self}/tests/agent-sandbox/github-keyring-lifecycle.py "
                "${lib.getExe llmAgents.codex} ${lib.getExe pkgs.gh}"
            )
            print(result)
            assert "cached thread repaired without restart; other clone denied" in result
        except Exception:
            print(machine.execute("cat /home/alice/codex-keyring-api.log")[1])
            print(machine.execute("journalctl --no-pager -u home-manager-alice.service | tail -50")[1])
            raise
  '';
}
