# ============================================================
#  OmniBus Ada GUI — Makefile
#
#  Requires: GNAT (gcc-ada) or Alire
#
#  Targets:
#    make build     — compile debug build
#    make release   — compile optimized build
#    make prove     — run SPARK formal verification
#    make run       — build + run on port 8340
#    make clean     — remove build artifacts
# ============================================================

.PHONY: build release prove run clean

GPR = omnibus_gui.gpr

# ── Default: debug build ──────────────────────────────────────

build:
	gprbuild -P $(GPR) -XMODE=debug -j0

# ── Release build ─────────────────────────────────────────────

release:
	gprbuild -P $(GPR) -XMODE=release -j0

# ── SPARK proof ───────────────────────────────────────────────

prove:
	gnatprove -P $(GPR) -XMODE=prove --level=2 -j0

# ── Run ───────────────────────────────────────────────────────

run: build
	./bin/omnibus-ada-gui

# ── Clean ─────────────────────────────────────────────────────

clean:
	gprclean -P $(GPR) 2>/dev/null || true
	rm -rf obj/* bin/*

# ── Windows-specific ──────────────────────────────────────────

build-win:
	gprbuild -P $(GPR) -XMODE=debug -XPLATFORM=windows -j0

run-win: build-win
	./bin/omnibus-ada-gui.exe

# ══════════════════════════════════════════════════════════════
#  GtkAda Native Desktop GUI
# ══════════════════════════════════════════════════════════════

GTK_GPR = omnibus_gtk_gui.gpr

gtk:
	gprbuild -P $(GTK_GPR) -XMODE=debug -j0

gtk-release:
	gprbuild -P $(GTK_GPR) -XMODE=release -j0

gtk-run: gtk
	./bin/omnibus-ada-gtk

gtk-win:
	gprbuild -P $(GTK_GPR) -XMODE=debug -XPLATFORM=windows -j0

gtk-run-win: gtk-win
	./bin/omnibus-ada-gtk.exe

clean-all: clean
	gprclean -P $(GTK_GPR) 2>/dev/null || true
