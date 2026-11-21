"""Static invariants of the rendered manifests (EXP-005-RWX). No cluster. Needs PyYAML (run via tests/run-local.sh)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness"))
import rwxlib as L  # noqa: E402

try:
    import yaml
except ImportError as e:  # the runner script supplies it with `uv run --with pyyaml`
    raise SystemExit("PyYAML is required: run tests/run-local.sh (uv run --with pyyaml ...)") from e

RUN = "20261119a"
NS = "herdrnetes-exp005-rwx-" + RUN


def load(name, **kw):
    return yaml.safe_load(L.render(name, RUN, **kw))


def pod(which="a", sel=None):
    return yaml.safe_load(L.render_pod(RUN, which, sel))


class TestNamespace(unittest.TestCase):
    def test_labels_and_psa(self):
        ns = load("namespace")
        self.assertEqual(ns["metadata"]["name"], NS)
        lab = ns["metadata"]["labels"]
        self.assertEqual(lab["herdrnetes.io/experiment"], "exp-005-rwx")
        self.assertEqual(lab["herdrnetes.io/run-id"], RUN)
        for k in ("enforce", "audit", "warn"):
            self.assertEqual(lab[f"pod-security.kubernetes.io/{k}"], "restricted")

    def test_never_live_or_exp005_namespace(self):
        self.assertNotIn(NS, ("herdrnetes-exp", "herdrnetes-exp005"))


class TestPVC(unittest.TestCase):
    def test_exact_claim(self):
        pvc = load("pvc")
        self.assertEqual(pvc["spec"]["accessModes"], ["ReadWriteMany"])
        self.assertEqual(pvc["spec"]["storageClassName"], "longhorn")
        self.assertEqual(pvc["spec"]["resources"]["requests"]["storage"], "1Gi")
        self.assertEqual(pvc["metadata"]["namespace"], NS)
        self.assertEqual(set(pvc["spec"]) - {"accessModes", "volumeMode", "storageClassName", "resources"}, set(),
                         "no selector/dataSource/volumeName")

    def test_no_storageclass_manifest_and_no_nas_class(self):
        files = os.listdir(L.MANIFEST_DIR)
        for f in files:
            text = "\n".join(ln for ln in open(os.path.join(L.MANIFEST_DIR, f)).read().splitlines()
                             if not ln.lstrip().startswith("#"))
            self.assertNotRegex(text, r"(?m)^kind:\s*StorageClass")
            self.assertNotIn("nfs", text)


class TestPods(unittest.TestCase):
    def test_two_pods_only_kind_pod(self):
        self.assertEqual(sorted(L.PODS.values()), ["rwx-a", "rwx-b"])
        for w in "ab":
            self.assertEqual(pod(w)["kind"], "Pod")

    def test_security_controls(self):
        for w in "ab":
            p = pod(w)
            s = p["spec"]
            sc = s["securityContext"]
            self.assertTrue(sc["runAsNonRoot"])
            self.assertEqual((sc["runAsUser"], sc["runAsGroup"], sc["fsGroup"]), (1000, 1000, 1000))
            self.assertEqual(sc["seccompProfile"]["type"], "RuntimeDefault")
            self.assertIs(s["automountServiceAccountToken"], False)
            for bad in ("hostNetwork", "hostPID", "hostIPC"):
                self.assertFalse(s.get(bad))
            self.assertNotIn("initContainers", s)
            self.assertNotIn("nodeName", s)
            self.assertEqual(len(s["containers"]), 1)
            c = s["containers"][0]
            csc = c["securityContext"]
            self.assertIs(csc["allowPrivilegeEscalation"], False)
            self.assertFalse(csc.get("privileged"))
            self.assertEqual(csc["capabilities"]["drop"], ["ALL"])
            self.assertTrue(csc["readOnlyRootFilesystem"])
            self.assertTrue(csc["runAsNonRoot"])
            self.assertNotIn("add", csc["capabilities"])
            for k in ("cpu", "memory"):
                self.assertIn(k, c["resources"]["requests"])
                self.assertIn(k, c["resources"]["limits"])

    def test_volumes_only_pvc_and_emptydir(self):
        for w in "ab":
            vols = pod(w)["spec"]["volumes"]
            kinds = sorted(next(k for k in v if k != "name") for v in vols)
            self.assertEqual(kinds, ["emptyDir", "persistentVolumeClaim"])
            pvc = [v for v in vols if "persistentVolumeClaim" in v][0]["persistentVolumeClaim"]
            self.assertEqual(pvc["claimName"], "rwx-scratch")
            self.assertNotIn("hostPath", str(vols))

    def test_image_pinned_by_digest_and_same_as_exp005(self):
        c = pod()["spec"]["containers"][0]
        self.assertRegex(c["image"], r"@sha256:[0-9a-f]{64}$")
        self.assertEqual(c["image"], L.IMAGE)
        exp5 = open(os.path.join(L.REPO_ROOT, "experiments", "exp-005", "manifests", "workspace-pod.yaml")).read()
        self.assertIn(L.IMAGE, exp5, "must match the EXP-005 scratch pod digest")

    def test_required_anti_affinity_on_hostname(self):
        for w in "ab":
            aa = pod(w)["spec"]["affinity"]["podAntiAffinity"]
            self.assertNotIn("preferredDuringSchedulingIgnoredDuringExecution", aa)
            terms = aa["requiredDuringSchedulingIgnoredDuringExecution"]
            self.assertEqual(len(terms), 2)
            for term in terms:
                self.assertEqual(term["topologyKey"], "kubernetes.io/hostname")
            self.assertEqual(terms[0]["labelSelector"]["matchLabels"],
                             {"herdrnetes.io/run-id": RUN, "herdrnetes.io/pod-group": "rwx-pair"})
            self.assertEqual(pod(w)["metadata"]["labels"]["herdrnetes.io/pod-group"], "rwx-pair")

    def test_second_term_keeps_pods_off_the_herdr_node(self):
        term = pod()["spec"]["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][1]
        self.assertEqual(term["labelSelector"]["matchLabels"], {"app.kubernetes.io/name": "herdr"})
        self.assertEqual(term["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "herdrnetes-exp"})
        other = yaml.safe_load(L.render_pod(RUN, "a", None, herdr_ns="other-herdr"))
        t2 = other["spec"]["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][1]
        self.assertEqual(t2["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "other-herdr"})
        with self.assertRaises(L.Refused):
            L.render_pod(RUN, "a", None, herdr_ns="Bad NS; x")

    def test_restart_policy_never(self):
        for w in "ab":
            self.assertEqual(pod(w)["spec"]["restartPolicy"], "Never")

    def test_labels(self):
        for w in "ab":
            lab = pod(w)["metadata"]["labels"]
            self.assertEqual(lab["herdrnetes.io/experiment"], "exp-005-rwx")
            self.assertEqual(lab["herdrnetes.io/run-id"], RUN)

    def test_node_selector_default_empty_and_runtime_injection(self):
        self.assertEqual(pod()["spec"]["nodeSelector"], {})
        self.assertEqual(pod(sel={"example.io/zone": "z1"})["spec"]["nodeSelector"], {"example.io/zone": "z1"})

    def test_no_hostnames_or_ips_committed(self):
        for f in os.listdir(L.MANIFEST_DIR):
            text = open(os.path.join(L.MANIFEST_DIR, f)).read()
            self.assertNotRegex(text, r"\b\d{1,3}(\.\d{1,3}){3}\b")
            self.assertNotRegex(text, r"(?i)nodeName|talos-|\.local\b|\.internal\b")

    def test_no_controllers_in_manifests(self):
        for f in os.listdir(L.MANIFEST_DIR):
            for doc in yaml.safe_load_all(open(os.path.join(L.MANIFEST_DIR, f)).read().replace("${", "X{")):
                self.assertIn(doc["kind"], L.ALLOWED_KINDS)


class TestNetworkPolicy(unittest.TestCase):
    def test_default_deny_namespace_scoped(self):
        np = load("networkpolicy")
        self.assertEqual(np["metadata"]["namespace"], NS)
        self.assertEqual(np["spec"]["podSelector"], {})
        self.assertEqual(sorted(np["spec"]["policyTypes"]), ["Egress", "Ingress"])
        self.assertNotIn("ingress", np["spec"])
        self.assertNotIn("egress", np["spec"])


class TestRenderGuards(unittest.TestCase):
    def test_unknown_variable_refused(self):
        with self.assertRaises(L.Refused):
            L.render("pod", RUN, POD_NAME="x")  # COMPONENT missing

    def test_all_templates_validate(self):
        for name in ("namespace", "pvc", "networkpolicy"):
            self.assertTrue(L.validate_manifest_text(L.render(name, RUN), NS, RUN))

    def test_wrong_namespace_or_run_rejected(self):
        text = L.render("pvc", RUN)
        with self.assertRaises(L.Refused):
            L.validate_manifest_text(text.replace(NS, "herdrnetes-exp"), NS, RUN)
        with self.assertRaises(L.Refused):
            L.validate_manifest_text(text.replace(RUN, "other"), NS, RUN)
        with self.assertRaises(L.Refused):
            L.validate_manifest_text(text.replace("kind: PersistentVolumeClaim", "kind: StorageClass"), NS, RUN)


if __name__ == "__main__":
    unittest.main()
