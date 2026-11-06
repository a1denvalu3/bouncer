import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from dashboard import app as dashboard


ROOT = Path(__file__).resolve().parents[1]


class GitScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.env = {
            **os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.test",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.test",
            "GITHUB_TOKEN": "", "GITHUB_PAT": "", "GH_TOKEN": "",
        }
        self.git("init", "-b", "main")
        self.root_oid = self.commit("root", "2024-01-01T12:00:00Z", "root.txt")
        self.direct_oid = self.commit("direct", "2024-01-02T12:00:00Z", "direct.txt")
        self.git("checkout", "-b", "feature")
        self.feature_oid = self.commit("feature", "2024-01-03T12:00:00Z", "feature.txt")
        self.git("checkout", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merge pull request #12", date="2024-01-05T12:00:00Z")
        self.merge_oid = self.git("rev-parse", "HEAD")
        self.git("checkout", "-b", "squashed")
        self.commit("squashed feature", "2024-01-06T12:00:00Z", "squashed.txt")
        self.git("checkout", "main")
        self.git("merge", "--squash", "squashed")
        self.git("commit", "-m", "Squash feature (#14)", date="2024-01-07T12:00:00Z")
        self.squash_oid = self.git("rev-parse", "HEAD")
        self.expected = [self.root_oid, self.direct_oid, self.merge_oid, self.squash_oid]

    def git(self, *args, date=None):
        env = dict(self.env)
        if date:
            env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        return subprocess.check_output(["git", *args], cwd=self.repo, env=env,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def commit(self, message, date, filename):
        (self.repo / filename).write_text(message + "\n")
        self.git("add", filename)
        self.git("commit", "-m", message, date=date)
        return self.git("rev-parse", "HEAD")

    def select(self, mode="backfill", start="", end=""):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/git_history.py"), "HEAD", mode, start, end],
            cwd=self.repo, env=self.env, capture_output=True, text=True,
        )
        return result

    def test_history_includes_direct_merge_and_squash_once_in_parent_order(self):
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), self.expected)
        self.assertNotIn(self.feature_oid, result.stdout)

    def test_date_and_commit_bounds_are_inclusive(self):
        for start, end in (("2024-01-02", "2024-01-05"),
                           (self.direct_oid[:12], self.merge_oid),
                           (self.direct_oid, "2024-01-05")):
            with self.subTest(start=start, end=end):
                result = self.select(start=start, end=end)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), self.expected[1:3])

    def test_date_filter_does_not_prune_out_of_order_timestamps(self):
        old_tip = self.commit("old timestamp", "2023-01-01T00:00:00Z", "old.txt")
        result = self.select(start="2024-01-01")
        self.assertEqual(result.stdout.splitlines(), self.expected)
        self.assertNotIn(old_tip, result.stdout)

    def test_invalid_bounds_fail_instead_of_silently_scanning(self):
        for start, end in (("12", "14"), ("2024-02-30", ""),
                           (self.squash_oid, self.root_oid),
                           (self.feature_oid, ""), ("--all", ""),
                           ("2025-01-01", "2024-01-01")):
            with self.subTest(start=start, end=end):
                result = self.select(start=start, end=end)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_manual_commit_selection_rejects_pr_numbers(self):
        self.assertEqual(self.select("single", self.merge_oid).stdout.strip(), self.merge_oid)
        self.assertNotEqual(self.select("single", "12").returncode, 0)

    def prepare_scanner(self):
        self.app = self.root / "app"
        self.out = self.root / "out"
        self.bin = self.root / "bin"
        self.out.mkdir()
        self.bin.mkdir()
        shutil.copytree(ROOT / "scripts", self.app / "scripts")
        shutil.copytree(ROOT / "templates", self.app / "templates")
        environment_file = self.root / 'environment'
        environment_file.touch()
        for path in (self.app / "scripts").glob("*.sh"):
            path.write_text(path.read_text().replace("/app", str(self.app)).replace("/out", str(self.out))
                            .replace('/etc/environment', str(environment_file)))
            path.chmod(0o755)
        gh_calls = self.root / 'gh-was-called'
        self.addCleanup(lambda: self.assertTrue(
            getattr(self, 'allow_gh', False) or not gh_calls.exists(), 'Token-free scan called gh'))
        self.write_executable("gh", f"import pathlib\npathlib.Path({str(gh_calls)!r}).touch()\nraise SystemExit(1)\n")
        self.write_executable("dhclient", "")
        # The same shell queries and migrations run against real SQLite. This
        # adapter substitutes only the missing SQLCipher executable/key pragma.
        self.write_executable("sqlcipher", """
import sqlite3, sys
args = sys.argv[1:]
while args and args[0].startswith('-'):
    option = args.pop(0)
    if option == '-cmd': args.pop(0)
connection = sqlite3.connect(args[0])
try:
    for statement in args[1].split(';'):
        if not statement.strip(): continue
        cursor = connection.execute(statement)
        for row in cursor:
            print('|'.join('' if value is None else str(value) for value in row))
    connection.commit()
finally:
    connection.close()
""")
        self.write_executable("systemd-nspawn", """
import os, subprocess, sys
args = sys.argv[1:]
env = {name: value for name, value in os.environ.items()
       if name.startswith(('TEST_', 'RESOLVE_')) or name in ('PATH', 'FAIL_COMMIT', 'CLEAN_COMMIT')}
index = 0
while index < len(args):
    if args[index] == '-E':
        name, value = args[index + 1].split('=', 1)
        env[name] = value
        index += 2
    elif args[index] == '/bin/bash':
        raise SystemExit(subprocess.run(args[index:], env=env).returncode)
    else:
        index += 1
raise SystemExit('missing sandbox command')
""")
        self.write_executable("opencode", """
import json, os, pathlib, sys
if sys.argv[1] == 'stats':
    print('Total Cost $0.01\\nInput 10\\nOutput 5\\nCache Read 0')
    raise SystemExit(0)
oid = os.environ['COMMIT_OID']
with open(os.environ['TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps({'oid': oid, 'prompt': sys.argv[-1],
        'diff': pathlib.Path('.commit_diff.txt').read_text(),
        'report_repo': os.environ.get('REPORT_REPO'),
        'github_token': os.environ.get('GITHUB_TOKEN')}) + '\\n')
if oid == os.environ.get('FAIL_COMMIT'):
    raise SystemExit(7)
report = pathlib.Path(os.environ['PR_REPORT'])
report.write_text('---\\nfinding: true\\nstatus: confirmed\\n---\\nFinding')
if oid == os.environ.get('CLEAN_COMMIT'):
    if sys.argv[-1].startswith('You are the independent'):
        report.unlink()
    else:
        report.write_text('---\\nfinding: false\\n---\\nClean commit')
ledger = pathlib.Path(os.environ['FINDINGS_LEDGER'])
ledger.write_text('## [Commit ' + oid + '] Finding\\n')
if oid == os.environ.get('RESOLVE_AT'):
    pathlib.Path(os.environ['PR_RESOLUTIONS']).write_text(
        os.environ['RESOLVE_OID'] + '|fixed quote \\' and pipe | safely\\n')
""")
        self.env.update({
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "DB_PASSPHRASE": "fixture-key", "OPENAI_API_KEY": "fixture-key",
            "OPENCODE_MODEL": "openrouter/test/model", "REPORT_REPO": "ignored/remote-reports",
            "TEST_CALLS": str(self.root / "calls.jsonl"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"url.file://{self.repo}.insteadOf",
            "GIT_CONFIG_VALUE_0": "https://github.com/test/repo.git",
        })
        result = self.run_script("migrate_db.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_executable(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run(["bash", str(self.app / "scripts" / name), *args],
                              cwd=self.app, env=self.env, capture_output=True, text=True, timeout=30)

    def query(self, sql):
        with sqlite3.connect(self.out / "bouncer.db") as db:
            return db.execute(sql).fetchall()

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_backfill_uses_only_git_local_reports_correct_diffs_and_resume(self):
        self.prepare_scanner()
        result = self.run_script("backfill.sh", "test/repo")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual([call['oid'] for call in calls], [oid for oid in self.expected for _ in range(2)])
        for call in calls:
            self.assertEqual(call['report_repo'], '')
            self.assertEqual(call['github_token'], '')
        self.assertIn('root.txt', calls[0]['diff'])
        self.assertIn('feature.txt', calls[4]['diff'])
        self.assertNotIn('direct.txt', calls[4]['diff'])
        self.assertIn('squashed.txt', calls[6]['diff'])
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(4,)])
        self.assertEqual(self.query('SELECT count(*) FROM pr_reviews'), [(0,)])
        self.assertEqual(self.query('SELECT count(*) FROM pr_reports WHERE pr_number IS NULL'), [(4,)])
        self.assertEqual(self.query('SELECT repo FROM backfill_ledger'), [('git:test/repo',)])
        self.assertEqual(self.run_script('backfill.sh', 'test/repo').returncode, 0)
        self.assertEqual(self.calls(), calls)

    def test_failure_does_not_advance_state_and_can_resume(self):
        self.prepare_scanner()
        self.env['FAIL_COMMIT'] = self.merge_oid
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(2,)])
        self.assertEqual(self.query('SELECT count(*) FROM pr_reports'), [(2,)])
        del self.env['FAIL_COMMIT']
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(4,)])

    def test_continuous_and_manual_entry_points_use_git_without_auth(self):
        self.prepare_scanner()
        result = self.run_script('review_pr.sh', 'test/repo', self.root_oid)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.env.update(REPOS='test/repo', PR_MAX_AGE='10 years')
        result = self.run_script('review.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(4,)])
        new_oid = self.commit('new commit', '2024-01-08T00:00:00Z', 'new.txt')
        result = self.run_script('review.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(5,)])
        self.assertEqual([call['oid'] for call in self.calls()[-2:]], [new_oid, new_oid])

    def test_clean_commits_advance_state_without_ingesting_reports(self):
        self.prepare_scanner()
        self.env['CLEAN_COMMIT'] = self.root_oid
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(4,)])
        self.assertEqual(self.query('SELECT count(*) FROM pr_reports'), [(3,)])

    def test_selected_branch_has_its_own_first_parent_history(self):
        self.prepare_scanner()
        self.env['GIT_SCAN_REF'] = 'origin/feature'
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call['oid'] for call in self.calls()],
                         [oid for oid in [self.root_oid, self.direct_oid, self.feature_oid] for _ in range(2)])

    def test_token_preserves_authenticated_pr_backfill(self):
        self.prepare_scanner()
        self.allow_gh = True
        self.env['GITHUB_PAT'] = 'fixture-github-token'
        self.write_executable('gh', f"""
import json, os, pathlib, subprocess, sys
assert os.environ['GITHUB_TOKEN'] == 'fixture-github-token'
args = sys.argv[1:]
with open({str(self.root / 'authenticated-calls.jsonl')!r}, 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args[:2] == ['repo', 'clone']:
    raise SystemExit(subprocess.run(['git', 'clone', 'https://github.com/test/repo.git', args[3]]).returncode)
elif args[:2] == ['repo', 'view']:
    print('2024-01-01T12:00:00Z')
elif args[:2] == ['pr', 'list']:
    print('[]')
elif args != ['auth', 'setup-git']:
    raise SystemExit('Unexpected gh command: ' + str(args))
""")
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Reporting mode: remote', result.stdout)
        calls = [json.loads(line) for line in (self.root / 'authenticated-calls.jsonl').read_text().splitlines()]
        self.assertIn(['auth', 'setup-git'], calls)
        self.assertTrue(any(call[:2] == ['pr', 'list'] for call in calls))
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(0,)])

    def test_commit_resolutions_use_sha_and_preserve_arbitrary_reason(self):
        self.prepare_scanner()
        self.env.update(RESOLVE_AT=self.direct_oid, RESOLVE_OID=self.root_oid)
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query(
            "SELECT resolved_by_commit, resolved_reason FROM pr_reports WHERE head_oid='" + self.root_oid + "'"
        ), [(self.direct_oid, "fixed quote ' and pipe | safely")])

    def test_author_enforcement_and_pr_number_bounds_fail_without_token(self):
        self.prepare_scanner()
        self.env['BACKFILL_ENFORCE_AUTHOR'] = '1'
        result = self.run_script('backfill.sh', 'test/repo')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('author-association', result.stdout)
        del self.env['BACKFILL_ENFORCE_AUTHOR']
        result = self.run_script('backfill.sh', 'test/repo', '12', '14')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.query('SELECT count(*) FROM git_reviews'), [(0,)])

    def test_schema_upgrade_preserves_pr_data_and_dashboard_handles_both_types(self):
        self.prepare_scanner()
        with sqlite3.connect(self.out / 'bouncer.db') as db:
            db.execute("INSERT INTO pr_reviews (repo, pr_number, head_oid) VALUES ('test/repo', 12, 'abc')")
            db.execute("INSERT INTO pr_reports (repo, pr_number, head_oid, report_text) VALUES ('test/repo', 12, 'abc', 'legacy')")
            db.execute('DROP TABLE git_reviews')
            db.execute('ALTER TABLE pr_reports DROP COLUMN resolved_by_commit')
            db.execute('DELETE FROM schema_migrations WHERE version=4')
        with patch.object(dashboard, 'run_sql', side_effect=self.dashboard_sql):
            self.assertEqual(dashboard.fetch_review_count(), 1)
        result = self.run_script('migrate_db.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.query('SELECT report_text FROM pr_reports'), [('legacy',)])
        result = self.run_script('review_pr.sh', 'test/repo', self.root_oid)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with patch.object(dashboard, 'run_sql', side_effect=self.dashboard_sql):
            reports = dashboard.fetch_reports()
            self.assertEqual({r['pr_number'] for r in reports}, {None, 12})
            self.assertEqual(dashboard.fetch_review_count(), 2)
        self.assertEqual(self.run_script('migrate_db.sh').returncode, 0)

    def dashboard_sql(self, sql):
        return '\n'.join('|'.join('' if value is None else str(value) for value in row)
                         for row in self.query(sql))


if __name__ == '__main__':
    unittest.main()
