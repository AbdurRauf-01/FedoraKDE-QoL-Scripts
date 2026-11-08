#!/usr/bin/env python3
"""
RAR archiver GUI for KDE.

Pick files/folders, set options, and the actual rar run happens in Konsole
(password is prompted there, never stored). Requires: rar, konsole, and
PyQt6 or PySide6  (sudo dnf install python3-pyqt6).
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

try:
    from PyQt6 import QtWidgets as W
except ImportError:
    try:
        from PySide6 import QtWidgets as W
    except ImportError:
        sys.exit("PyQt6 or PySide6 not found. Install with: sudo dnf install python3-pyqt6")

COMPRESSION = [
    ("Store (no compression)", "0"),
    ("Fastest", "1"),
    ("Fast", "2"),
    ("Normal", "3"),
    ("Good", "4"),
    ("Best", "5"),
]
DICTIONARY = [
    ("128 KB", "128k"), ("256 KB", "256k"), ("512 KB", "512k"),
    ("1 MB", "1m"), ("2 MB", "2m"), ("4 MB", "4m"), ("8 MB", "8m"),
    ("16 MB", "16m"), ("32 MB", "32m"), ("64 MB", "64m"), ("128 MB", "128m"),
    ("256 MB", "256m"), ("512 MB", "512m"), ("1 GB", "1g"),
]

# Defaults
DEF_COMPRESSION = "3"      # Normal
DEF_DICTIONARY = "32m"
DEF_RECOVERY = 20          # percent
DEF_VOLUME_MB = 1950


# ---------------------------------------------------------------- helpers ---
def q(s):
    return shlex.quote(s)


def bash_array(name, values):
    return f"{name}=(" + " ".join(q(v) for v in values) + ")"


def existing_outputs(out_path):
    """The archive itself plus any <name>.partN.rar volumes."""
    d, f = os.path.split(out_path)
    base = f[:-4] if f.lower().endswith(".rar") else f
    pat = re.compile("^" + re.escape(base) + r"\.part\d+\.rar$")
    hits = [out_path] if os.path.exists(out_path) else []
    try:
        hits += [os.path.join(d, n) for n in os.listdir(d) if pat.match(n)]
    except OSError:
        pass
    return hits


def per_file_jobs(items, out_override):
    """One job per file: (source_dir, file_name, output_path). Subfolders are skipped."""
    jobs, seen, skipped = [], set(), 0

    def add(src_dir, name):
        nonlocal skipped
        if (src_dir, name) in seen:
            return
        seen.add((src_dir, name))
        out = os.path.join(out_override or src_dir, name + ".rar")
        if existing_outputs(out):
            skipped += 1
        else:
            jobs.append((src_dir, name, out))

    for it in items:
        if os.path.isdir(it):
            try:
                entries = sorted(os.scandir(it), key=lambda e: e.name.lower())
            except OSError:
                continue
            for e in entries:
                if e.is_file() and not e.name.lower().endswith(".rar"):
                    add(it, e.name)
        elif os.path.isfile(it):
            add(os.path.dirname(it), os.path.basename(it))
    return jobs, skipped


HEADER = ["#!/usr/bin/env bash", "trap 'rm -f -- \"$0\"' EXIT"]


def single_script(opts, pwflag, parent, archive, names):
    lines = HEADER + [
        bash_array("OPTS", opts + ([pwflag] if pwflag else [])),
        bash_array("NAMES", names),
        f"ARCHIVE={q(archive)}",
        f"cd -- {q(parent)} || {{ echo 'Cannot enter source folder'; exit 1; }}",
        'rar a "${OPTS[@]}" -- "$ARCHIVE" "${NAMES[@]}"',
        "rc=$?",
        "echo",
        'if [ $rc -eq 0 ]; then echo "Archive created: $ARCHIVE"; else echo "rar failed (exit $rc)"; fi',
    ]
    return "\n".join(lines) + "\n"


PER_FILE_BODY = r'''
PW=""
if [ -n "$PWFLAG" ]; then
    read -rsp "Archive password: " PW; echo
    read -rsp "Confirm password: " PW2; echo
    [ -n "$PW" ] || { echo "Password cannot be empty."; exit 1; }
    [ "$PW" = "$PW2" ] || { echo "Passwords do not match."; exit 1; }
    unset PW2
fi

ok=0; fail=0
for i in "${!NAMES[@]}"; do
    out=${OUTS[$i]}
    if [ -e "$out" ]; then
        echo "SKIP (already exists): $out"
        skip=$((skip + 1))
        continue
    fi
    pwopt=()
    if [ -n "$PWFLAG" ]; then pwopt=("$PWFLAG$PW"); fi
    if ( cd -- "${SRC[$i]}" && rar a "${OPTS[@]}" "${pwopt[@]}" -- "$out" "${NAMES[$i]}" >/dev/null ); then
        echo "OK: $out"
        ok=$((ok + 1))
    else
        echo "FAILED: ${NAMES[$i]}"
        fail=$((fail + 1))
    fi
done
unset PW

echo
echo "Done. Created: $ok  Failed: $fail  Skipped: $skip"
'''


def per_file_script(opts, pwflag, jobs, skipped):
    lines = HEADER + [
        bash_array("OPTS", opts),
        f"PWFLAG={q(pwflag)}",
        bash_array("SRC", [j[0] for j in jobs]),
        bash_array("NAMES", [j[1] for j in jobs]),
        bash_array("OUTS", [j[2] for j in jobs]),
        f"skip={skipped}",
    ]
    return "\n".join(lines) + "\n" + PER_FILE_BODY


# ------------------------------------------------------------------- GUI ---
class Window(W.QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("RAR Archiver")
        self.setMinimumWidth(640)
        self.items = []
        self.last_dir = os.path.expanduser("~")
        self.name_manual = False
        self.dir_manual = False

        root = W.QVBoxLayout(self)

        # --- items
        g_items = W.QGroupBox("Items to archive")
        l_items = W.QVBoxLayout(g_items)
        self.listw = W.QListWidget()
        self.listw.setSelectionMode(W.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.listw.setMinimumHeight(130)
        l_items.addWidget(self.listw)
        row = W.QHBoxLayout()
        for text, fn in (
            ("Add folder(s)…", self.add_folders),
            ("Add files…", self.add_files),
            ("Remove selected", self.remove_selected),
            ("Clear", self.clear_items),
        ):
            b = W.QPushButton(text)
            b.clicked.connect(lambda checked=False, f=fn: f())
            row.addWidget(b)
        l_items.addLayout(row)
        root.addWidget(g_items)

        # --- output
        g_out = W.QGroupBox("Output")
        f_out = W.QFormLayout(g_out)
        self.per_file = W.QCheckBox("Separate RAR for each file inside the selected folder(s)")
        self.per_file.setToolTip("Off: everything goes into one RAR.\n"
                                 "On: every file directly inside each selected folder gets its own RAR.\n"
                                 "Subfolders and existing .rar files are skipped.")
        self.per_file.toggled.connect(self.refresh_auto)
        f_out.addRow(self.per_file)
        self.name_edit = W.QLineEdit()
        self.name_edit.textEdited.connect(self.on_name_edited)
        f_out.addRow("Archive name:", self.name_edit)
        dir_row = W.QHBoxLayout()
        self.outdir_edit = W.QLineEdit()
        self.outdir_edit.setPlaceholderText("Default: next to the selected item(s)")
        self.outdir_edit.textEdited.connect(self.on_dir_edited)
        browse = W.QPushButton("Browse…")
        browse.clicked.connect(lambda checked=False: self.browse_out())
        dir_row.addWidget(self.outdir_edit)
        dir_row.addWidget(browse)
        f_out.addRow("Save in:", dir_row)
        root.addWidget(g_out)

        # --- options
        g_opt = W.QGroupBox("Options")
        f_opt = W.QFormLayout(g_opt)
        self.comp = W.QComboBox()
        for label, val in COMPRESSION:
            self.comp.addItem(label, val)
        self.comp.setCurrentIndex(self.comp.findData(DEF_COMPRESSION))
        self.comp.currentIndexChanged.connect(self.on_comp_changed)
        f_opt.addRow("Compression:", self.comp)

        self.dict = W.QComboBox()
        for label, val in DICTIONARY:
            self.dict.addItem(label, val)
        self.dict.setCurrentIndex(self.dict.findData(DEF_DICTIONARY))
        f_opt.addRow("Dictionary size:", self.dict)

        self.rr = W.QSpinBox()
        self.rr.setRange(0, 100)
        self.rr.setSuffix(" %")
        self.rr.setSpecialValueText("Off")
        self.rr.setValue(DEF_RECOVERY)
        f_opt.addRow("Recovery record:", self.rr)

        self.vol = W.QSpinBox()
        self.vol.setRange(0, 10_000_000)
        self.vol.setSuffix(" MB")
        self.vol.setSpecialValueText("Off")
        self.vol.setValue(DEF_VOLUME_MB)
        f_opt.addRow("Split to volumes:", self.vol)

        grid = W.QGridLayout()
        self.pw = W.QCheckBox("Password")
        self.pw.setChecked(True)
        self.pw.toggled.connect(self.on_pw_toggled)
        self.enc_names = W.QCheckBox("Encrypt file names")
        self.enc_names.setChecked(True)
        self.solid = W.QCheckBox("Create solid archive")
        self.b2 = W.QCheckBox("BLAKE2 file checksum")
        self.b2.setChecked(True)
        grid.addWidget(self.pw, 0, 0)
        grid.addWidget(self.enc_names, 0, 1)
        grid.addWidget(self.solid, 1, 0)
        grid.addWidget(self.b2, 1, 1)
        f_opt.addRow(grid)
        root.addWidget(g_opt)

        # --- buttons
        btns = W.QHBoxLayout()
        btns.addStretch(1)
        cancel = W.QPushButton("Cancel")
        cancel.clicked.connect(lambda checked=False: self.close())
        go = W.QPushButton("Create archive")
        go.setDefault(True)
        go.clicked.connect(lambda checked=False: self.create())
        btns.addWidget(cancel)
        btns.addWidget(go)
        root.addLayout(btns)

        self.on_comp_changed()

    # ---- item list
    def add_paths(self, paths):
        for p in paths:
            p = os.path.abspath(p)
            if p not in self.items:
                self.items.append(p)
                self.listw.addItem(p + ("/" if os.path.isdir(p) else ""))
        if paths:
            self.last_dir = os.path.dirname(os.path.abspath(paths[0]))
        self.refresh_auto()

    def add_folders(self):
        # Qt's own dialog (not the native KDE one) so files stay visible,
        # with multi-select enabled so several folders can be picked at once.
        dlg = W.QFileDialog(self, "Select folder(s) to archive", self.last_dir)
        dlg.setFileMode(W.QFileDialog.FileMode.Directory)
        dlg.setOption(W.QFileDialog.Option.DontUseNativeDialog, True)
        for view in dlg.findChildren(W.QListView) + dlg.findChildren(W.QTreeView):
            view.setSelectionMode(W.QAbstractItemView.SelectionMode.ExtendedSelection)
        if dlg.exec():
            self.add_paths(dlg.selectedFiles())

    def add_files(self):
        paths, _ = W.QFileDialog.getOpenFileNames(self, "Select files to archive", self.last_dir)
        if paths:
            self.add_paths(paths)

    def remove_selected(self):
        rows = sorted({self.listw.row(i) for i in self.listw.selectedItems()}, reverse=True)
        for r in rows:
            del self.items[r]
            self.listw.takeItem(r)
        self.refresh_auto()

    def clear_items(self):
        self.items.clear()
        self.listw.clear()
        self.refresh_auto()

    # ---- auto defaults
    def on_name_edited(self, text):
        self.name_manual = bool(text.strip())
        if not self.name_manual:
            self.refresh_auto()

    def on_dir_edited(self, text):
        self.dir_manual = bool(text.strip())
        if not self.dir_manual:
            self.refresh_auto()

    def refresh_auto(self, *_):
        per_file = self.per_file.isChecked()
        if not self.name_manual:
            if len(self.items) == 1:
                p = self.items[0]
                base = os.path.basename(p)
                self.name_edit.setText(base if os.path.isdir(p) else os.path.splitext(base)[0])
            else:
                self.name_edit.setText("Archive" if self.items else "")
        if not self.dir_manual:
            # Single archive: folder that contains the selection.
            # Separate mode: left empty = each archive next to its own file.
            if self.items and not per_file:
                self.outdir_edit.setText(os.path.dirname(self.items[0]))
            else:
                self.outdir_edit.setText("")
        self.name_edit.setEnabled(not per_file)

    def browse_out(self):
        d = W.QFileDialog.getExistingDirectory(
            self, "Save archives in", self.outdir_edit.text().strip() or self.last_dir)
        if d:
            self.outdir_edit.setText(d)
            self.dir_manual = True

    # ---- option interplay
    def on_comp_changed(self, *_):
        store = self.comp.currentData() == "0"
        self.dict.setEnabled(not store)
        self.solid.setEnabled(not store)

    def on_pw_toggled(self, checked):
        self.enc_names.setEnabled(checked)

    # ---- run
    def build_opts(self):
        level = self.comp.currentData()
        opts = [f"-m{level}"]
        if level != "0":
            opts.append(f"-md{self.dict.currentData()}")
            if self.solid.isChecked():
                opts.append("-s")
        if self.rr.value():
            opts.append(f"-rr{self.rr.value()}")
        if self.vol.value():
            opts.append(f"-v{self.vol.value()}m")
        if self.b2.isChecked():
            opts.append("-htb")
        if not self.pw.isChecked():
            pwflag = ""
        else:
            pwflag = "-hp" if self.enc_names.isChecked() else "-p"
        return opts, pwflag

    def error(self, msg):
        W.QMessageBox.warning(self, "RAR Archiver", msg)

    def create(self):
        if not self.items:
            self.error("Add at least one file or folder first.")
            return
        opts, pwflag = self.build_opts()
        if self.per_file.isChecked():
            script = self.prepare_per_file(opts, pwflag)
        else:
            script = self.prepare_single(opts, pwflag)
        if script:
            self.launch(script)

    def prepare_single(self, opts, pwflag):
        parent = os.path.dirname(self.items[0])
        if any(os.path.dirname(p) != parent for p in self.items):
            self.error("All items must be in the same parent directory so the stored "
                       "paths stay relative.\nRun it again for items in other locations.")
            return None
        base = self.name_edit.text().strip()
        if base.lower().endswith(".rar"):
            base = base[:-4]
        if not base or "/" in base:
            self.error("Enter a valid archive name (no slashes).")
            return None
        outdir = os.path.abspath(os.path.expanduser(self.outdir_edit.text().strip() or parent))
        try:
            os.makedirs(outdir, exist_ok=True)
        except OSError as e:
            self.error(f"Cannot create {outdir}:\n{e}")
            return None
        archive = os.path.join(outdir, base + ".rar")
        hits = existing_outputs(archive)
        if hits:
            extra = "" if len(hits) == 1 else f" (+ {len(hits) - 1} volume files)"
            ans = W.QMessageBox.question(
                self, "Overwrite?", f"{archive}{extra}\nalready exists. Overwrite it?")
            if ans != W.QMessageBox.StandardButton.Yes:
                return None
            for h in hits:
                try:
                    os.remove(h)
                except OSError as e:
                    self.error(f"Cannot delete {h}:\n{e}")
                    return None
        names = [os.path.basename(p) for p in self.items]
        return single_script(opts, pwflag, parent, archive, names)

    def prepare_per_file(self, opts, pwflag):
        override = None
        if self.dir_manual and self.outdir_edit.text().strip():
            override = os.path.abspath(os.path.expanduser(self.outdir_edit.text().strip()))
            try:
                os.makedirs(override, exist_ok=True)
            except OSError as e:
                self.error(f"Cannot create {override}:\n{e}")
                return None
        jobs, skipped = per_file_jobs(self.items, override)
        if not jobs:
            extra = f" ({skipped} already have archives)" if skipped else ""
            self.error("No files to archive" + extra + ".")
            return None
        return per_file_script(opts, pwflag, jobs, skipped)

    def launch(self, script):
        fd, path = tempfile.mkstemp(prefix="rar-gui-", suffix=".sh")
        with os.fdopen(fd, "w") as f:
            f.write(script)
        os.chmod(path, 0o700)
        subprocess.Popen(["konsole", "--hold", "-e", "bash", path], start_new_session=True)
        self.close()


def main():
    app = W.QApplication(sys.argv)
    missing = [c for c in ("rar", "konsole") if not shutil.which(c)]
    if missing:
        W.QMessageBox.critical(None, "RAR Archiver", "Not found in PATH: " + ", ".join(missing))
        return 1
    win = Window()
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
