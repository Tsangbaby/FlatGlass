from pathlib import Path
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def between(text: str, start: str, end: str) -> str:
    first = text.index(start)
    last = text.index(end, first + len(start))
    return text[first:last]


class FlatGlassRepairContracts(unittest.TestCase):
    def test_render_translation_unit_imports_hook_and_image_declarations(self):
        render = source("FlatGlassIconServices/FGRender.m")
        self.assertIn('#import "FGCompat.h"', render)
        self.assertIn('#import "FGWrap.h"', render)

    def test_iconservices_links_its_compression_dependency(self):
        self.assertIn("compression_decode_buffer(", source("FlatGlassIconServices/FGResolve.m"))
        makefile = source("FlatGlassIconServices/Makefile")
        libraries = re.search(r"^FlatGlassIconServices_LIBRARIES\s*=\s*([^\n]*)$", makefile, re.MULTILINE)
        self.assertIsNotNone(libraries, "link the original renderer's compression dependency explicitly")
        self.assertIn("compression", libraries[1].split())

    def test_off_mode_is_passthrough_before_asset_catalog_work(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = between(render, "id FGResourceImage(", "id FGComposedImage(")
        gate = body[:body.index("@try")]
        self.assertTrue("state == 3" in gate, "missing explicit Off state (Mode 2 + 1)")
        self.assertTrue("FGOriginalResourceImage" in gate, "Off must use the saved system renderer")
        self.assertLess(gate.index("state == 3"), body.index("FGIndexForResource(self)"))

    def test_resource_render_route_matches_four_mode_state_mapping(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = between(render, "id FGResourceImage(", "id FGComposedImage(")
        route = body[body.index("CGImageRef rendered ="):body.index("if (rendered)")]
        self.assertTrue("(state == 2)" in route, "state 2 should use the glass-content renderer")
        self.assertTrue("NGCreateGlassIconContent" in route, "missing state 2 renderer")
        self.assertTrue("NGCreateFlatIcon" in route, "states 1 and 4 use the flat-resource pass")

    def test_resource_request_rejects_invalid_size_and_wraps_using_point_size(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = between(render, "id FGResourceImage(", "@protocol FGComposedImageResult")
        gate = body[:body.index("FGIndexForResource(self)")]
        self.assertTrue("!isfinite(points) || points <= 0" in gate
                        and "!isfinite(scale) || scale <= 0" in gate,
                        "do not attempt custom rendering for invalid dimensions or scale")
        self.assertRegex(body, r"imageScale\s*=\s*\(CGFloat\)pixels / points;")

    def test_catalog_appearance_is_read_as_a_boxed_integer(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = between(render, "static uint32_t FGAppearanceForResource(", "id FGResourceImage(")
        self.assertNotRegex(body, r"\[[^\]\n]*performSelector:",
                            "catalogAppearance is a scalar, not a retained ObjC object")
        self.assertTrue('valueForKey:@"catalogAppearance"' in body
                        and "unsignedLongLongValue" in body,
                        "use KVC's boxed scalar and reject out-of-range appearances")

    def test_composed_hook_calls_original_once_before_any_custom_work(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = render[render.index("id FGComposedImage("):]
        original_call = "FGOriginalComposedImage)(self, _cmd, size, scale)"
        self.assertEqual(body.count(original_call), 1, "saved compositor must be invoked once")
        self.assertLess(body.index(original_call), body.index("notify_get_state"))
        self.assertTrue("return original;" in body, "every fallback must preserve the saved result")

    def test_layered_primary_resource_is_resolved_via_its_provider(self):
        wrap = source("FlatGlassIconServices/FGWrap.m")
        body = wrap[wrap.index("BOOL FGHasLayeredPrimaryResource("):]
        self.assertTrue('@"resourceProvider"' in body, "missing compositor resource-provider lookup")
        self.assertTrue('dlsym(RTLD_DEFAULT, "kISPrimaryResourceKey")' in wrap,
                        "resolve the native key when exported")
        self.assertTrue("resourceNamed:" in body and "withObject:FGPrimaryResourceKey()" in body,
                        "provider must resolve the primary catalog resource")
        self.assertTrue("[provider performSelector:named" in body,
                        "resourceNamed: must be sent to the provider, not the compositor element")
        self.assertTrue("FGCatalogHasStack(primary, imageName)" in body,
                        "the reconstruction's catalog index takes a resource, not a catalog")

    def test_image_wrapper_declares_arc_initializer_signature(self):
        wrap = source("FlatGlassIconServices/FGWrap.m")
        self.assertRegex(wrap, r"-\s*\(instancetype\)initWithCGImage:\(CGImageRef\)\w+ scale:\(CGFloat\)\w+\s*;")

    def test_compositor_uses_original_image_recipe_and_binary_size_boundary(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = render[render.index("id FGComposedImage("):]
        self.assertTrue("CGImageRef artwork" in body, "missing original-result image extraction")
        self.assertTrue("imageResult.CGImage" in body,
                        "post-process the compositor result, not elements.firstObject")
        self.assertTrue("imageResult = original;" in body and "imageResult.scale" in body,
                        "take both image and scale from the original result")
        self.assertTrue('@"recipe"' in body and "FGReadCompositorProperty(primary," in body
                        and "FGReadCompositorProperty(self," in body,
                        "read the first element's recipe, falling back to the compositor's")
        self.assertTrue("ISiOSAppRecipe" in body and "isKindOfClass" in body,
                        "only process the recovered app-recipe class")
        self.assertTrue("w != h || w >= 0x401" in body,
                        "only square images up to and including 1024 px are eligible")
        self.assertTrue("FGHasLayeredPrimaryResource(primary)" in body,
                        "the layered-resource predicate selects the rim branch")
        self.assertTrue("NGCreateGlassedImage(artwork, 0)" in body,
                        "the non-layered branch uses the recovered zero flags")

    def test_compositor_uses_correct_mode_route(self):
        render = source("FlatGlassIconServices/FGRender.m")
        body = render[render.index("id FGComposedImage("):]
        self.assertRegex(body, r"\(state != 2 && state != 4\)")
        self.assertRegex(body, r"state == 4 \|\| FGHasLayeredPrimaryResource\(primary\)")

    def test_svg_document_stays_alive_through_draw_and_is_released_once(self):
        render = source("FlatGlassIconServices/FGRender.m")
        self.assertTrue("static BOOL FGDrawSVG(" in render, "keep SVG creation, drawing and cleanup together")
        self.assertFalse("FGDecodeSVG(" in render, "no separately boxed SVG pointer")
        body = render[render.index("static BOOL FGDrawSVG("):render.index("static CGImageRef FGDecodeBitmap(")]
        self.assertEqual(body.count("create((__bridge CFDataRef)data, 0)"), 1)
        self.assertEqual(body.count("release(document)"), 1)
        self.assertLess(body.index("draw(ctx, document)"), body.index("release(document)"))
        self.assertTrue("!release" in body[:body.index("create((__bridge CFDataRef)data, 0)")],
                        "do not create a document when its releaser is unavailable")
        self.assertFalse("dataWithBytes:&document" in render)

    def test_svg_scales_validated_canvas_to_layer_frame(self):
        body = between(source("FlatGlassIconServices/FGRender.m"),
                       "static BOOL FGDrawSVG(", "static CGImageRef FGDecodeBitmap(")
        self.assertIn('"CGSVGDocumentGetCanvasSize"', body,
                      "the reference scales the document to the target layer, not a 1:1 canvas")
        self.assertTrue("CGSize size = canvasSize(document);" in body
                        and "isfinite(size.width)" in body and "isfinite(size.height)" in body
                        and "size.width > 0" in body and "size.height > 0" in body,
                        "reject empty or invalid document geometry before drawing")
        self.assertRegex(body, r"CGContextScaleCTM\(ctx,\s*frame\.size\.width / size\.width,\s*-frame\.size\.height / size\.height\)")
        self.assertRegex(body, r"@finally\s*\{\s*release\(document\);")

    def test_springboard_reads_isHidden_as_boolean(self):
        refresh = source("FlatGlassRefresh/Tweak.x")
        self.assertTrue(re.search(r"BOOL\s+hidden\s*=\s*\[\(UIView \*\)view isHidden\]", refresh),
                        "call UIKit's BOOL getter via UIView, not the object-only helper")
        self.assertFalse(re.search(r'ObjectValue\(view,\s*@"isHidden"\)', refresh))

    def test_preferences_controller_loads_root_specifiers(self):
        prefs = source("FlatGlassPrefs/FGSettingsListController.m")
        self.assertRegex(prefs, r"-\s*\(NSMutableArray\s*\*\)specifiers\s*\{")
        self.assertIn('loadSpecifiersFromPlistName:@"Root" target:self', prefs)

    def test_preferences_mode_ids_and_loader_entry_match(self):
        config = plistlib.loads((ROOT / "FlatGlassPrefs/Resources/Root.plist").read_bytes())
        row, = [row for row in config["items"] if row.get("key") == "Mode"]
        self.assertEqual(list(zip(row["validTitles"], row["validValues"])), [
            ("Remove Highlights", 0), ("Edge Only", 3), ("Edge and Artwork", 1), ("Off", 2),
        ])
        mode_ids = dict(re.findall(r"\b(FGMode\w+)\s*=\s*(\d+)\s*,", source("Shared/FGCommon.h")))
        self.assertEqual({name: int(value) for name, value in mode_ids.items()}, {
            "FGModeFlat": 0, "FGModeEdge": 3, "FGModeEdgeArtwork": 1, "FGModeOff": 2,
        })
        self.assertEqual((row["default"], row["get"], row["set"]), (0, "readMode:", "writeMode:specifier:"))
        path = ROOT / "layout/Library/PreferenceLoader/Preferences/FlatGlassPrefs.plist"
        entry = plistlib.loads(path.read_bytes())["entry"]
        self.assertIs(entry["isController"], True)
        self.assertEqual((entry["bundle"], entry["detail"]), ("FlatGlassPrefs", "FGSettingsListController"))
        info = plistlib.loads((ROOT / "FlatGlassPrefs/Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundlePrincipalClass"], entry["detail"])
        self.assertEqual(info["CFBundleExecutable"], entry["bundle"])
        self.assertIn("FlatGlassPrefs_RESOURCE_DIRS = Resources", source("FlatGlassPrefs/Makefile"))

    def test_preview_catalog_uses_typed_calls_and_keeps_catalog_alive(self):
        body = between(source("flatglass/main.m"), "@implementation FlatRenderer", "#pragma mark - Helpers")
        self.assertTrue("id<FGPreviewCatalog> _catalogRef;" in body, "catalog needs strong ownership")
        self.assertTrue("initWithURL:[NSURL fileURLWithPath:path] error:&error" in body,
                        "NSError output is an indirect pointer, not an ObjC argument to performSelector")
        self.assertTrue("imageWithName:name scaleFactor:scale" in body,
                        "pass the CGFloat in its scalar argument slot")
        self.assertFalse("performSelector:" in body, "do not send a scalar or CF reference as id")

    def test_daemon_uses_scheme_aware_install_paths(self):
        makefile = source("Makefile")
        daemon_makefile = source("flatglass/Makefile")
        daemon = source("flatglass/main.m")
        self.assertFalse("export PREFIX = /var/jb" in makefile, "PREFIX belongs to Theos's toolchain")
        self.assertIn("THEOS_PACKAGE_SCHEME ?= rootless", makefile)
        self.assertIn("-DFG_INSTALL_PREFIX=", daemon_makefile)
        self.assertIn("$(THEOS_PACKAGE_INSTALL_PREFIX)", daemon_makefile)
        self.assertIn("FGInstallPath(", daemon)
        self.assertFalse('"/var/jb/Library/Themes/' in daemon)
        self.assertFalse('"/var/jb/var/mobile/' in daemon, "mobile preferences are not package payload")
        self.assertIn("Architecture: iphoneos-arm\n", source("control"))

    def test_catalog_storage_getters_use_arc_typed_object_dispatch(self):
        catalog = source("FlatGlassIconServices/FGCatalog.m")
        for start, end in (("static NSArray *FGArrayForSelector(", "static NSDictionary *FGDictionaryForSelector("),
                           ("static NSDictionary *FGDictionaryForSelector(", "NGCatalogIndex *FGIndexForResource(")):
            with self.subTest(getter=start):
                body = between(catalog, start, end)
                self.assertIn("[object respondsToSelector:sel]", body)
                self.assertIn("((id (*)(id, SEL))objc_msgSend)(object, sel)", body)
                self.assertNotIn("performSelector:", body)
                self.assertIn("@catch", body)

    def test_roothide_install_paths_use_jbroot_for_jailbreak_owned_files(self):
        makefile = source("Makefile")
        self.assertIn("THEOS_PACKAGE_SCHEME),roothide)", makefile)
        daemon_makefile = source("flatglass/Makefile")
        self.assertIn("ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\nflatglass_LIBRARIES += roothide\nendif", daemon_makefile)
        daemon = source("flatglass/main.m")
        self.assertIn('#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)\n#import <roothide.h>', daemon)
        body = between(daemon, "static NSString *FGInstallPath(", "#pragma mark")
        self.assertIn("#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)", body)
        self.assertIn("return jbroot(path);", body)
        self.assertIn("return [FG_INSTALL_PREFIX stringByAppendingString:path];", body)
        self.assertNotIn('jbroot(@"/var/mobile/', daemon,
                         "real mobile-owned preferences must not be remapped into jbroot")

    def test_launch_daemon_plist_is_staged_with_the_selected_prefix(self):
        template = ROOT / "templates/local.lumid.flatglass.plist.in"
        self.assertTrue(template.is_file(), "need a source template outside the packaged layout")
        body = template.read_text(encoding="utf-8")
        self.assertIn("@THEOS_PACKAGE_INSTALL_PREFIX@/usr/libexec/flatglass", body)
        makefile = source("Makefile")
        self.assertIn("tools/stage_launchd_plist.py", makefile)
        relative = Path("Library/LaunchDaemons/local.lumid.flatglass.plist")
        self.assertFalse((ROOT / "layout" / relative).exists(), "avoid a second static launchd plist")
        for prefix in ("", "/var/jb"):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as stage:
                cmd = [sys.executable, "-B", str(ROOT / "tools/stage_launchd_plist.py"),
                       f"--prefix={prefix}", stage]
                proc = subprocess.run(cmd, text=True, capture_output=True, timeout=10)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                output = Path(stage) / relative
                job = plistlib.loads(output.read_bytes())
                self.assertEqual(job["ProgramArguments"], [prefix + "/usr/libexec/flatglass", "--watch"])
                self.assertEqual((job["Label"], job["UserName"]), ("local.lumid.flatglass", "mobile"))
                self.assertEqual(output.stat().st_mode & 0o777, 0o644)
        with tempfile.TemporaryDirectory() as stage:
            proc = subprocess.run([sys.executable, "-B", str(ROOT / "tools/stage_launchd_plist.py"),
                                   "--prefix=/unexpected", stage], text=True, capture_output=True, timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse((Path(stage) / relative).exists())

    def test_roothide_launch_daemon_stages_a_jbroot_relative_program(self):
        relative = Path("Library/LaunchDaemons/local.lumid.flatglass.plist")
        helper = ROOT / "tools/stage_launchd_plist.py"
        with tempfile.TemporaryDirectory() as stage:
            proc = subprocess.run([sys.executable, "-B", str(helper), "--scheme=roothide",
                                   "--prefix=", stage], capture_output=True, text=True, timeout=10)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            job = plistlib.loads((Path(stage) / relative).read_bytes())
            self.assertEqual(job["ProgramArguments"], ["/usr/libexec/flatglass", "--watch"])
            self.assertNotIn("__Patched", job, "RootHide launchctl owns the path rewrite")
            self.assertEqual((job["Label"], job["UserName"], job["GroupName"]),
                             ("local.lumid.flatglass", "mobile", "mobile"))
        with tempfile.TemporaryDirectory() as stage:
            proc = subprocess.run([sys.executable, "-B", str(helper), "--scheme=roothide",
                                   "--prefix=/var/jb", stage], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse((Path(stage) / relative).exists())

    def test_staged_control_keeps_identity_and_uses_the_matching_icon_path(self):
        helper = ROOT / "tools/stage_launchd_plist.py"
        self.assertIn("before-package::", source("Makefile"))
        for arch, prefix, accepted in (("iphoneos-arm", "", True),
                                       ("iphoneos-arm64", "/var/jb", True),
                                       ("iphoneos-arm64", "", False)):
            with self.subTest(arch=arch, prefix=prefix), tempfile.TemporaryDirectory() as stage:
                control = Path(stage) / "DEBIAN/control"
                control.parent.mkdir()
                original = re.sub(r"^Architecture: .+$", f"Architecture: {arch}",
                                  source("control"), flags=re.MULTILINE)
                control.write_text(original, encoding="utf-8")
                proc = subprocess.run([sys.executable, "-B", str(helper), "--control",
                                       f"--prefix={prefix}", stage],
                                      text=True, capture_output=True, timeout=10)
                staged = control.read_text(encoding="utf-8")
                if accepted:
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    icon = "Icon: file://" + prefix + "/Library/PreferenceBundles/FlatGlassPrefs.bundle/icon@3x.png"
                    self.assertEqual(staged, re.sub(r"^Icon: .+$", icon, original, flags=re.MULTILINE))
                else:
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertEqual(staged, original)

    def test_roothide_control_validates_architecture_and_omits_fixed_icon_url(self):
        helper = ROOT / "tools/stage_launchd_plist.py"
        for arch in ("iphoneos-arm64e", "iphoneos-arm64"):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as stage:
                control = Path(stage) / "DEBIAN/control"
                control.parent.mkdir()
                original = source("control").replace("Architecture: iphoneos-arm\n", f"Architecture: {arch}\n")
                control.write_text(original, encoding="utf-8")
                proc = subprocess.run([sys.executable, "-B", str(helper), "--control",
                                       "--scheme=roothide", "--prefix=", stage],
                                      text=True, capture_output=True, timeout=10)
                if arch == "iphoneos-arm64e":
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    self.assertEqual(control.read_text(), re.sub(r"^Icon: .*\n", "", original, flags=re.MULTILINE))
                else:
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertEqual(control.read_text(), original)

    def test_package_scripts_select_resolved_install_prefix(self):
        for rel in ("layout/DEBIAN/postinst", "layout/DEBIAN/prerm"):
            body = source(rel)
            self.assertTrue("DPKG_MAINTSCRIPT_ARCH" in body, "choose the package's own architecture, not file existence")
            self.assertEqual((ROOT / rel).stat().st_mode & 0o777, 0o755)
            # No real launchctl or daemon may run. 'upgrade' does not take the prerm disable branch.
            # Pipe a separate descriptor around the scripts' stdout redirection;
            # make bootout fail so the legacy unload branch is also exercised.
            mock = 'exec 3>&1\nlaunchctl() { printf "%s\\n" "$*" >&3; [ "$1" != bootout ]; }\n'
            if rel.endswith("postinst"):
                body = body.replace('/usr/libexec/flatglassdiag', 'fgd_test_install_probe')
                mock += 'fgd_test_install_probe() { return 0; }\n'
            cmd = ["/bin/sh", "-c", mock + body, rel, "upgrade"]
            for arch, prefix in (("iphoneos-arm", ""), ("iphoneos-arm64", "/var/jb"),
                                 ("iphoneos-arm64e", ""), ("unknown", None)):
                with self.subTest(script=rel, arch=arch):
                    proc = subprocess.run(cmd, env={**os.environ, "DPKG_MAINTSCRIPT_ARCH": arch},
                                          text=True, capture_output=True, timeout=10)
                    if prefix is None:
                        self.assertNotEqual(proc.returncode, 0)
                        self.assertEqual(proc.stdout, "")
                    else:
                        self.assertEqual(proc.returncode, 0, proc.stderr)
                        job = f"{prefix}/Library/LaunchDaemons/local.lumid.flatglass.plist"
                        expected = ["bootout user/foreground/local.lumid.flatglass",
                                    "bootout system/local.lumid.flatglass", f"unload {job}"]
                        if rel.endswith("postinst"):
                            expected.append(f"bootstrap system {job}")
                        self.assertEqual(proc.stdout.splitlines(), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
