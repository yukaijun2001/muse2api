#!/usr/bin/env python3
"""离线验证部署更新流程；配置校验使用真实 Compose，不会安装软件或启动容器。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muse2api-deploy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("MUSE2API_", "COMPOSE_", "GIT_"))
        }
        self.env.update({
            "GIT_AUTHOR_NAME": "Deploy Test", "GIT_COMMITTER_NAME": "Deploy Test",
            "GIT_AUTHOR_EMAIL": "deploy@example.invalid",
            "GIT_COMMITTER_EMAIL": "deploy@example.invalid",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "LC_ALL": "C",
        })

    def command(self, *args, env=None, check=True):
        result = subprocess.run(
            [str(arg) for arg in args], env=env or self.env,
            capture_output=True, text=True, timeout=30,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def bash(self, script, *args, env=None, check=True):
        return self.command(
            "bash", "-c", 'source "$1"; shift; ' + script,
            "deploy-test", ROOT / "deploy.sh", *args, env=env, check=check,
        )

    def config_fixture(self):
        if not shutil.which("docker"):
            self.skipTest("需要安装 Docker CLI 和 Compose（不需要 Docker daemon）")
        result = self.command("docker", "compose", "version", check=False)
        if result.returncode:
            self.skipTest("需要安装 Docker Compose")
        install = self.root / "install"
        install.mkdir()
        for name in (".env.example", "docker-compose.yml"):
            shutil.copy2(ROOT / name, install / name)
        return install

    def configure(self, install, env=None, check=True):
        return self.bash('INSTALL_DIR=$1; configure_environment', install, env=env, check=check)

    def values(self, install):
        result = self.command(
            "docker", "compose", "--env-file", install / ".env",
            "-f", install / "docker-compose.yml", "config", "--environment",
        )
        return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def git_fixture(self):
        remote = self.root / "remote.git"
        upstream = self.root / "upstream"
        self.command("git", "init", "--bare", remote)
        self.command("git", "init", upstream)
        self.command("git", "-C", upstream, "checkout", "-b", "main")
        (upstream / ".gitignore").write_text(".env\ndata/\n", encoding="utf-8")
        (upstream / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
        (upstream / ".env.example").write_text("MUSE2API_KEY=\n", encoding="utf-8")
        self.command("git", "-C", upstream, "add", ".")
        self.command("git", "-C", upstream, "commit", "-m", "initial")
        self.command("git", "-C", upstream, "remote", "add", "origin", remote)
        self.command("git", "-C", upstream, "push", "origin", "main")
        return remote, upstream

    def sync(self, install, remote, check=True):
        return self.bash('INSTALL_DIR=$1; REPO_URL=$2; BRANCH=main; update_source', install, remote, check=check)

    def test_generated_key_and_repeat_deploy_preserve_data(self):
        install = self.config_fixture()
        self.configure(install)
        values = self.values(install)
        self.assertRegex(values["MUSE2API_KEY"], r"^m2a_[0-9a-f]{48}$")
        self.assertEqual(values["MUSE2API_PORT"], "10002")
        self.assertEqual((install / ".env").stat().st_mode & 0o777, 0o600)
        (install / "data/accounts.json").write_text('[{"id":"saved"}]', encoding="utf-8")
        with (install / ".env").open("a", encoding="utf-8") as stream:
            stream.write("# custom configuration\nMUSE2API_CHAT_TIMEOUT=480\n")
        self.configure(install)
        self.assertEqual(self.values(install)["MUSE2API_KEY"], values["MUSE2API_KEY"])
        self.assertIn("# custom configuration", (install / ".env").read_text(encoding="utf-8"))
        self.assertEqual((install / "data/accounts.json").read_text(encoding="utf-8"), '[{"id":"saved"}]')
        config = json.loads(self.command(
            "docker", "compose", "--env-file", install / ".env",
            "-f", install / "docker-compose.yml", "config", "--format", "json",
        ).stdout)["services"]["muse2api"]
        self.assertEqual(config["ports"][0]["published"], "10002")
        self.assertEqual(config["ports"][0]["target"], 10002)
        self.assertEqual(config["environment"]["MUSE2API_CHAT_TIMEOUT"], "480")

    def test_existing_key_quoting_and_explicit_settings(self):
        install = self.config_fixture()
        for key in ("m2a_$literal#hash", "m2a_quote'and\"slash\\", "m2a_simple"):
            env = dict(self.env, MUSE2API_KEY=key, MUSE2API_PORT="11002",
                       MUSE2API_PUBLIC_BASE="https://api.example.com/")
            self.configure(install, env=env)
            self.assertEqual(self.values(install)["MUSE2API_KEY"], key)
            self.configure(install)
            values = self.values(install)
            self.assertEqual(values["MUSE2API_KEY"], key)
            self.assertEqual(values["MUSE2API_PORT"], "11002")
            self.assertEqual(values["MUSE2API_PUBLIC_BASE"], "https://api.example.com")

    def test_placeholder_replaced_and_invalid_port_rejected(self):
        install = self.config_fixture()
        path = install / ".env"
        path.write_text("MUSE2API_KEY=m2a_your_secret_admin_key_here\n", encoding="utf-8")
        self.configure(install)
        self.assertRegex(self.values(install)["MUSE2API_KEY"], r"^m2a_[0-9a-f]{48}$")
        previous = path.read_bytes()
        for port in ("0", "65536", "invalid"):
            result = self.configure(install, env=dict(self.env, MUSE2API_PORT=port), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), previous)

    def test_clone_update_and_dirty_checkout_protection(self):
        remote, upstream = self.git_fixture()
        install = self.root / "installed project"
        self.sync(install, remote)
        (install / ".env").write_text("MUSE2API_KEY=saved\n", encoding="utf-8")
        (install / "data").mkdir()
        (install / "data/accounts.json").write_text("saved accounts\n", encoding="utf-8")
        (upstream / "release.txt").write_text("latest\n", encoding="utf-8")
        self.command("git", "-C", upstream, "add", "release.txt")
        self.command("git", "-C", upstream, "commit", "-m", "release")
        self.command("git", "-C", upstream, "push", "origin", "main")
        self.sync(install, remote)
        self.assertEqual((install / "release.txt").read_text(encoding="utf-8"), "latest\n")
        self.assertEqual((install / ".env").read_text(encoding="utf-8"), "MUSE2API_KEY=saved\n")
        self.assertEqual((install / "data/accounts.json").read_text(encoding="utf-8"), "saved accounts\n")
        (install / "release.txt").write_text("local edit\n", encoding="utf-8")
        self.assertNotEqual(self.sync(install, remote, check=False).returncode, 0)
        self.assertEqual((install / "release.txt").read_text(encoding="utf-8"), "local edit\n")

    def test_divergent_history_and_wrong_branch_fail(self):
        remote, upstream = self.git_fixture()
        install = self.root / "install"
        self.sync(install, remote)
        (install / "local.txt").write_text("local\n", encoding="utf-8")
        self.command("git", "-C", install, "add", "local.txt")
        self.command("git", "-C", install, "commit", "-m", "local")
        (upstream / "remote.txt").write_text("remote\n", encoding="utf-8")
        self.command("git", "-C", upstream, "add", "remote.txt")
        self.command("git", "-C", upstream, "commit", "-m", "remote")
        self.command("git", "-C", upstream, "push", "origin", "main")
        before = self.command("git", "-C", install, "rev-parse", "HEAD").stdout
        self.assertNotEqual(self.sync(install, remote, check=False).returncode, 0)
        self.assertEqual(self.command("git", "-C", install, "rev-parse", "HEAD").stdout, before)
        self.command("git", "-C", install, "checkout", "-b", "other")
        self.assertNotEqual(self.sync(install, remote, check=False).returncode, 0)

    def test_linux_server_flow_and_repeat_deploy(self):
        """运行完整脚本，用本地 Git 远端和假的系统命令隔离安装 / 部署副作用。"""
        remote, upstream = self.git_fixture()
        for name in (".env.example", "docker-compose.yml"):
            shutil.copy2(ROOT / name, upstream / name)
        shutil.copy2(ROOT / "deploy.sh", upstream / "deploy.sh")
        self.command("git", "-C", upstream, "add", ".")
        self.command("git", "-C", upstream, "commit", "-m", "deployment")
        self.command("git", "-C", upstream, "push", "origin", "main")
        install = self.root / "server"
        log = self.root / "commands.jsonl"
        commands = self.root / "bin"
        commands.mkdir()
        fake = commands / "fake-command"
        fake.write_text("#!/usr/bin/env python3\n" + '''
import json, os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['DEPLOY_TEST_LOG'], 'a') as stream:
    stream.write(json.dumps([name, *args]) + '\\n')
if name == 'uname':
    print('Linux' if args == ['-s'] else 'x86_64')
elif name == 'sudo':
    os.execvp(args[0], args)
elif name == 'docker':
    if args[:2] == ['compose', 'version']:
        print('Docker Compose version v2.40.0')
    elif args[:2] == ['buildx', 'version']:
        print('github.com/docker/buildx v0.30.0')
    elif 'config' in args and '--environment' in args:
        path = Path(args[args.index('--env-file') + 1])
        values = {}
        for line in path.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                value = value.strip()
                if value.startswith('"'):
                    value = json.loads(value).replace('$$', '$')
                values[key.strip()] = value
        for key in ('MUSE2API_KEY', 'MUSE2API_PORT', 'MUSE2API_PUBLIC_BASE'):
            print(key + '=' + (os.environ.get(key) or values.get(key, '')))
elif name == 'curl':
    if args[-1] == 'https://api.ipify.org':
        print('8.8.8.8')
    elif args[-1].endswith('/v1/models'):
        if sys.stdin.read().strip() != 'Authorization: Bearer ' + os.environ['MUSE2API_KEY']:
            sys.exit(22)
    elif not args[-1].endswith('/healthz'):
        sys.exit(1)
elif name == 'ufw':
    if args == ['status']:
        print('Status: active')
elif name == 'firewall-cmd':
    print('running' if args == ['--state'] else 'success')
''', encoding="utf-8")
        fake.chmod(0o755)
        for name in ("uname", "sudo", "docker", "curl", "ufw", "firewall-cmd"):
            (commands / name).symlink_to(fake)
        env = dict(self.env, PATH=str(commands) + os.pathsep + self.env["PATH"],
                   DEPLOY_TEST_LOG=str(log), MUSE2API_INSTALL_DIR=str(install),
                   MUSE2API_REPO_URL=str(remote))
        first = self.command("bash", ROOT / "deploy.sh", env=env)
        self.assertIn("部署完成", first.stdout)
        self.assertIn("http://8.8.8.8:10002/admin?key=m2a_", first.stdout)
        saved = (install / ".env").read_text(encoding="utf-8")
        (install / "data/accounts.json").write_text("saved account", encoding="utf-8")
        self.command("bash", install / "deploy.sh", env=env)
        self.assertEqual((install / ".env").read_text(encoding="utf-8"), saved)
        self.assertEqual((install / "data/accounts.json").read_text(encoding="utf-8"), "saved account")
        events = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(sum(event[0] == 'docker' and event[-3:] == ['up', '-d', '--build'] for event in events), 2)
        self.assertTrue(any(event[0] == 'ufw' and event[1:] == ['allow', '10002/tcp'] for event in events))
        self.assertTrue(any(event[0] == 'firewall-cmd' and event[1:] == ['--permanent', '--add-port=10002/tcp'] for event in events))
        self.assertFalse(any('get.docker.com' in arg for event in events for arg in event))
        self.assertFalse(any('Bearer' in arg or 'm2a_' in arg for event in events for arg in event))


if __name__ == "__main__":
    unittest.main(verbosity=2)
