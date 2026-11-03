# ---------------------------------------------------------------------------
# Regresión del pipeline en Vivado (decisión 028): corre pipeline_tb una vez por
# línea de build/regresion/corridas.txt, que escribe scripts/regresion.py.
#
#   python scripts/regresion.py [--modo sin_riesgos|forwarding|completo] [programas...]
#   y en la Tcl Console de Vivado (o con vivado -mode batch -source):
#       source <ruta-al-repo>/scripts/regresion.tcl
#
# Usa el proyecto abierto o, si no hay ninguno, lo crea con create_project.tcl.
# Compila y elabora una sola vez; las demás corridas reusan el snapshot con
# launch_simulation -step simulate y solo cambian los plusargs.
#
# Cada corrida deja su log en build/regresion/logs/<etiqueta>.log. Pasa si la
# última línea que empieza con "TEST " empieza con "TEST PASSED" (verificacion.md
# §6). Una corrida en la que Vivado da error, o en la que xsim no deja log, cuenta
# como falla y el script sigue con la próxima. Al final imprime el resumen, lo
# guarda en build/regresion/resumen.txt y, si alguna corrida falló, termina con
# error (en batch, Vivado sale con código 1).
# ---------------------------------------------------------------------------
set reg_root [file normalize [file join [file dirname [info script]] ..]]
set reg_dir  [file join $reg_root build regresion]
set reg_list [file join $reg_dir corridas.txt]

if {![file exists $reg_list]} {
    error "No existe $reg_list: corré antes python scripts/regresion.py"
}
set f [open $reg_list r]
set corridas [list]
foreach linea [split [read $f] "\n"] {
    if {[string trim $linea] ne ""} { lappend corridas $linea }
}
close $f

if {[catch {current_project}]} {
    source [file join $reg_root scripts create_project.tcl]
}
set sim_dir [file join [get_property DIRECTORY [current_project]] \
                 [current_project].sim sim_1 behav xsim]

set log_dir [file join $reg_dir logs]
file mkdir $log_dir
foreach viejo [glob -nocomplain [file join $log_dir *.log]] { file delete $viejo }

# Resultado de una corrida: la última línea "TEST ..." del log, o "" si no hay
proc reg_resultado {log} {
    set f [open $log r]
    set ultima ""
    foreach linea [split [read $f] "\n"] {
        if {[string match "TEST *" $linea]} { set ultima $linea }
    }
    close $f
    return $ultima
}

set_property top pipeline_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
catch {close_sim -force}        ;# por si quedó abierta una simulación, por ejemplo de ondas.tcl

set resumen [list]
set fallas  0
set primera 1
foreach corrida $corridas {
    set etiqueta [lindex $corrida 0]
    set opts "-testplusarg DIR=[file join $reg_root build tb [lindex $corrida 1]]"
    foreach plusarg [lrange $corrida 2 end] { append opts " -testplusarg $plusarg" }
    set_property -name {xsim.simulate.xsim.more_options} -value $opts -objects [get_filesets sim_1]

    # Sin el log viejo, una corrida en la que xsim no llega a correr no puede
    # pasar con el resultado de la anterior. Un error corta solo esta corrida:
    # si fue al compilar, la siguiente vuelve a intentar el launch completo
    set sim_log [file join $sim_dir simulate.log]
    if {[catch {
        file delete -force $sim_log
        if {$primera} {
            launch_simulation
            set primera 0
        } else {
            launch_simulation -step simulate
        }
        run all
        close_sim
    } err]} {
        catch {close_sim -force}
        lappend resumen "FALLA $etiqueta: [lindex [split $err "\n"] 0]"
        incr fallas
        continue
    }
    if {![file exists $sim_log]} {
        lappend resumen "FALLA $etiqueta: xsim no dejó simulate.log"
        incr fallas
        continue
    }

    set log [file join $log_dir $etiqueta.log]
    file copy -force $sim_log $log
    set res [reg_resultado $log]
    if {[string match "TEST PASSED*" $res]} {
        lappend resumen "ok    $etiqueta: $res"
    } else {
        if {$res eq ""} { set res "sin línea TEST" }
        lappend resumen "FALLA $etiqueta: $res"
        incr fallas
    }
}
set_property -name {xsim.simulate.xsim.more_options} -value {} -objects [get_filesets sim_1]

lappend resumen "REGRESION: [expr {[llength $corridas] - $fallas}] de [llength $corridas] corridas con TEST PASSED"
set f [open [file join $reg_dir resumen.txt] w]
puts $f [join $resumen "\n"]
close $f
puts [join $resumen "\n"]
if {$fallas > 0} {
    error "regresión: $fallas corridas fallaron (logs en $log_dir)"
}
