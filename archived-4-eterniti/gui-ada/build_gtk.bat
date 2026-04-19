@echo off
set PATH=C:\Users\cazan\AppData\Local\alire\cache\toolchains\gnat_native_15.2.1_346e2e00\bin;C:\Users\cazan\AppData\Local\alire\cache\toolchains\gprbuild_25.0.1_1bcdf5e8\bin;%PATH%
set GPR_PROJECT_PATH=C:\Users\cazan\AppData\Local\alire\cache\builds\gtkada_26.0.0_489d17d3\9bbd709b0510e269c7ceb000a77391dbd13357758175001299c6ff93ca07457e\src;C:\Users\cazan\AppData\Local\alire\cache\builds\gtkada_26.0.0_489d17d3\9bbd709b0510e269c7ceb000a77391dbd13357758175001299c6ff93ca07457e
cd /d "%~dp0"
gprbuild -P omnibus_gtk_gui.gpr -XMODE=debug -XPLATFORM=windows -j0 > build_log.txt 2>&1
type build_log.txt
