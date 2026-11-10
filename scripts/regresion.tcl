# ---------------------------------------------------------------------------
# Regresión del pipeline en Vivado (decisión 028): corre pipeline_tb una vez por
# línea de build/regresion/corridas.txt, que escribe scripts/regresion.py.
#
#   python scripts/regresion.py [--modo sin_riesgos|forwarding|forwarding_stall|completo] [programas...]
#   y en la Tcl Console de Vivado (o con vivado -mode batch -source):
#       source <ruta-al-repo>/scripts/regresion.tcl
#
# Usa el proyecto abierto o, si no hay ninguno, lo crea con create_project.tcl.
# Cada pasada es una sola simulación (decisión 033): el script escribe
# build/regresion/lista_tb.txt desde corridas.txt, y pipeline_tb, con +LISTA, corre
# las corridas una tras otra, con el core en reset entre una y otra.
#
# Cada corrida deja su parte del log en build/regresion/logs/<etiqueta>.log; el log
# entero queda en pipeline_tb.log. Pasa si la última línea que empieza con "TEST "
# empieza con "TEST PASSED" (verificacion.md §6). Si Vivado da error, xsim no deja
# log, o el log no tiene la parte de una corrida o su línea TEST, esa corrida
# queda como ERROR y cuenta como falla. Al final imprime el resumen, lo
# guarda en build/regresion/resumen.txt y, si alguna corrida falló, termina con
# error (en batch, Vivado sale con código 1).
#
# Después de los programas corre los testbenches unitarios de
# build/regresion/unitarios.txt (decisión 032), si regresion.py la escribió: cada
# uno con su top y compilando desde cero, porque el snapshot es otro. Su log va a
# build/regresion/logs/unit/<tb>.log y se decide igual, por la última línea TEST.
#
# Con mutantes (regresion.py --mutante, decisión 031) corre primero la lista sin
# mutante, como referencia: si alguna corrida falla, los mutantes no se corren.
# Después la corre una vez por mutante: deshabilita el archivo original de rtl/ y
# simula con la copia de build/mutantes/, sin tocar rtl/. Los logs van a
# build/regresion/logs/<mutante>/. Un mutante está detectado si alguna corrida
# termina en TEST FAILED, y queda en ERROR si alguna quedó sin resultado (por
# ejemplo, la copia no compila): ahí no se sabe si se detecta. El script termina
# con error si algún mutante no se detecta o queda en ERROR. Al terminar, o si
# algo falla en el medio, el proyecto queda como estaba.
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

# La lista para pipeline_tb (+LISTA, decisión 033): etiqueta, directorio absoluto,
# final, pausas y semilla. pipeline_tb lee cada campo hasta el próximo espacio
if {[regexp {\s} $reg_root]} {
    error "La ruta del repositorio tiene espacios ($reg_root): pipeline_tb no puede leer los directorios de +LISTA"
}
set tb_list [file join $reg_dir lista_tb.txt]
set f [open $tb_list w]
foreach corrida $corridas {
    set final 0
    set pausas 0
    set semilla 0
    foreach plusarg [lrange $corrida 2 end] {
        if {$plusarg eq "FINAL"} {
            set final 1
        } elseif {[regexp {^PAUSAS=(-?[0-9]+)$} $plusarg -> semilla]} {
            set pausas 1
        } else {
            close $f
            error "corridas.txt: no se conoce el plusarg $plusarg en '$corrida'"
        }
    }
    puts $f "[lindex $corrida 0] [file join $reg_root build tb [lindex $corrida 1]] $final $pausas $semilla"
}
close $f

# Mutantes: nombre, archivo original y copia mutada (relativos a la raíz). Sin la
# lista, solo la pasada sin mutante
set mut_list [file join $reg_dir mutantes.txt]
set mutantes [list]
if {[file exists $mut_list]} {
    set f [open $mut_list r]
    foreach linea [split [read $f] "\n"] {
        if {[string trim $linea] ne ""} { lappend mutantes $linea }
    }
    close $f
}

# Testbenches unitarios (decisión 032): un top por línea. Sin la lista, ninguno
set unit_list [file join $reg_dir unitarios.txt]
set unitarios [list]
if {[file exists $unit_list]} {
    set f [open $unit_list r]
    foreach linea [split [read $f] "\n"] {
        if {[string trim $linea] ne ""} { lappend unitarios [string trim $linea] }
    }
    close $f
}

if {[catch {current_project}]} {
    source [file join $reg_root scripts create_project.tcl]
}
set sim_dir [file join [get_property DIRECTORY [current_project]] \
                 [current_project].sim sim_1 behav xsim]

set log_dir [file join $reg_dir logs]
file mkdir $log_dir
foreach viejo [glob -nocomplain [file join $log_dir *]] { file delete -force $viejo }

# Resultado de una corrida: la última línea "TEST ..." del log, o "" si no hay
proc reg_resultado {log} {
    set f [open $log r]
    fconfigure $f -encoding utf-8
    set ultima ""
    foreach linea [split [read $f] "\n"] {
        if {[string match "TEST *" $linea]} { set ultima $linea }
    }
    close $f
    return $ultima
}

# Deja el proyecto sin mutantes: saca de sim_1 las copias de build/mutantes/ y vuelve
# a habilitar los archivos de rtl/ deshabilitados. Se llama antes y después de cada
# pasada, así que también arregla un proyecto que quedó a medias.
proc reg_restaurar {} {
    set copias [get_files -quiet -of_objects [get_filesets sim_1] \
                    -filter {NAME =~ "*/build/mutantes/*"}]
    if {[llength $copias] > 0} { remove_files -fileset sim_1 $copias }
    set apagados [get_files -quiet -of_objects [get_filesets sources_1] \
                      -filter {IS_ENABLED == 0 && NAME =~ "*/rtl/*"}]
    foreach a $apagados { set_property IS_ENABLED true $a }
}

# Simula con la copia mutada en lugar del original
proc reg_mutar {reg_root original copia} {
    set orig [get_files -quiet -of_objects [get_filesets sources_1] \
                  -filter "NAME =~ \"*/$original\""]
    if {[llength $orig] != 1} { error "mutante: $original no está en sources_1" }
    set_property IS_ENABLED false $orig
    add_files -fileset sim_1 -norecurse [file join $reg_root $copia]
}

# Una pasada: una simulación de pipeline_tb con +LISTA (decisión 033), con los logs
# en dir. Devuelve {fallas errores lineas}: fallas son las corridas que terminan sin
# TEST PASSED; errores, las que quedan sin resultado (Vivado da error, xsim no deja
# log, o el log no tiene la parte de la corrida o su línea TEST). Los errores
# también están en fallas
proc reg_pasada {corridas tb_list sim_dir dir} {
    set lineas [list]
    set fallas [list]
    set errores [list]

    # Sin el log viejo, una pasada en la que xsim no llega a correr no puede pasar
    # con el resultado de la anterior
    set sim_log [file join $sim_dir simulate.log]
    set_property -name {xsim.simulate.xsim.more_options} \
        -value "-testplusarg LISTA=$tb_list" -objects [get_filesets sim_1]
    set err_sim ""
    if {[catch {
        file delete -force $sim_log
        launch_simulation
        run all
        close_sim
    } err]} {
        catch {close_sim -force}
        set err_sim [lindex [split $err "\n"] 0]
    }
    set_property -name {xsim.simulate.xsim.more_options} -value {} -objects [get_filesets sim_1]

    # El log partido en las líneas "CORRIDA <etiqueta>": cada parte va hasta la
    # próxima, o hasta la línea "LISTA:" del final
    set partes [dict create]
    if {[file exists $sim_log]} {
        file copy -force $sim_log [file join $dir pipeline_tb.log]
        set f [open $sim_log r]
        fconfigure $f -encoding utf-8
        set actual ""
        foreach linea [split [read $f] "\n"] {
            if {[regexp {^CORRIDA (\S+)$} $linea -> etiqueta]} {
                set actual $etiqueta
            } elseif {[string match "LISTA: *" $linea]} {
                set actual ""
            }
            if {$actual ne ""} { dict lappend partes $actual $linea }
        }
        close $f
    }

    foreach corrida $corridas {
        set etiqueta [lindex $corrida 0]
        if {![dict exists $partes $etiqueta]} {
            if {$err_sim ne ""} {
                set motivo $err_sim
            } elseif {![file exists $sim_log]} {
                set motivo "xsim no dejó simulate.log"
            } else {
                set motivo "no está en el log de pipeline_tb"
            }
            lappend lineas "ERROR $etiqueta: $motivo"
            lappend fallas $etiqueta
            lappend errores $etiqueta
            continue
        }
        set log [file join $dir $etiqueta.log]
        set f [open $log w]
        fconfigure $f -encoding utf-8
        puts $f [join [dict get $partes $etiqueta] "\n"]
        close $f
        set res [reg_resultado $log]
        if {[string match "TEST PASSED*" $res]} {
            lappend lineas "ok    $etiqueta: $res"
        } elseif {$res eq ""} {
            lappend lineas "ERROR $etiqueta: sin línea TEST"
            lappend fallas $etiqueta
            lappend errores $etiqueta
        } else {
            lappend lineas "FALLA $etiqueta: $res"
            lappend fallas $etiqueta
        }
    }
    return [list $fallas $errores $lineas]
}

# Los testbenches unitarios, con los logs en dir. Cada uno cambia el top, así que
# launch_simulation compila y elabora de nuevo. Devuelve {fallas lineas}; una
# corrida sin resultado (ERROR) cuenta como falla
proc reg_unitarios {unitarios sim_dir dir} {
    set lineas [list]
    set fallas [list]
    set_property -name {xsim.simulate.xsim.more_options} -value {} -objects [get_filesets sim_1]
    foreach tb $unitarios {
        set sim_log [file join $sim_dir simulate.log]
        if {[catch {
            file delete -force $sim_log
            set_property top $tb [get_filesets sim_1]
            update_compile_order -fileset sim_1
            launch_simulation
            run all
            close_sim
        } err]} {
            catch {close_sim -force}
            lappend lineas "ERROR unit $tb: [lindex [split $err "\n"] 0]"
            lappend fallas $tb
            continue
        }
        if {![file exists $sim_log]} {
            lappend lineas "ERROR unit $tb: xsim no dejó simulate.log"
            lappend fallas $tb
            continue
        }
        set log [file join $dir $tb.log]
        file copy -force $sim_log $log
        set res [reg_resultado $log]
        if {[string match "TEST PASSED*" $res]} {
            lappend lineas "ok    unit $tb: $res"
        } elseif {$res eq ""} {
            lappend lineas "ERROR unit $tb: sin línea TEST"
            lappend fallas $tb
        } else {
            lappend lineas "FALLA unit $tb: $res"
            lappend fallas $tb
        }
    }
    set_property top pipeline_tb [get_filesets sim_1]
    return [list $fallas $lineas]
}

set_property top pipeline_tb [get_filesets sim_1]
catch {close_sim -force}        ;# por si quedó abierta una simulación, por ejemplo de ondas.tcl

# La pasada sin mutante ("") va siempre primero: con mutantes es la referencia. Si
# falla, los mutantes no se corren, porque una corrida que ya falla no dice nada de
# un mutante (verificacion.md §8.7)
set resumen [list]
set fallas_total 0
set no_detectados [list]
set con_error [list]
foreach mutante [concat [list ""] $mutantes] {
    if {$mutante ne "" && $fallas_total > 0} {
        lappend resumen "MUTANTES: no se corren, la pasada sin mutante tiene $fallas_total corridas que fallan"
        break
    }
    # Cada pasada compila desde cero: sin reset_simulation, xsim puede reusar lo
    # compilado de la pasada anterior (la copia mutada o el original)
    reg_restaurar
    catch {reset_simulation -simset sim_1 -mode behavioral}
    set dir $log_dir
    if {$mutante ne ""} {
        lassign $mutante nombre original copia
        set dir [file join $log_dir $nombre]
        file mkdir $dir
    }
    if {[catch {
        if {$mutante ne ""} { reg_mutar $reg_root $original $copia }
        update_compile_order -fileset sim_1
        lassign [reg_pasada $corridas $tb_list $sim_dir $dir] fallas errores lineas
    } err]} {
        set fallas [list error]
        set errores [list error]
        set lineas [list "ERROR: [lindex [split $err "\n"] 0]"]
    }
    reg_restaurar

    set n [llength $corridas]
    if {$mutante eq ""} {
        set resumen [concat $resumen $lineas]
        lappend resumen "REGRESION: [expr {$n - [llength $fallas]}] de $n corridas con TEST PASSED"
        set fallas_total [llength $fallas]
    } elseif {[llength $errores] > 0} {
        # Sin resultado no se sabe si el mutante se detecta: se muestra el mensaje
        set msj [lindex $lineas [lsearch -glob $lineas "ERROR*"]]
        lappend resumen "MUTANTE $nombre: ERROR, [llength $errores] de $n corridas sin resultado: $msj"
        lappend con_error $nombre
    } elseif {[llength $fallas] > 0} {
        lappend resumen "MUTANTE $nombre: detectado, fallan [llength $fallas] de $n corridas: [join $fallas {, }]"
    } else {
        lappend resumen "MUTANTE $nombre: NO DETECTADO, $n de $n corridas con TEST PASSED"
        lappend no_detectados $nombre
    }
}
# Testbenches unitarios, sin mutantes (regresion.py no escribe la lista con --mutante)
if {[llength $unitarios] > 0} {
    reg_restaurar
    set dir [file join $log_dir unit]
    file mkdir $dir
    if {[catch {
        lassign [reg_unitarios $unitarios $sim_dir $dir] fallas lineas
    } err]} {
        set fallas [list error]
        set lineas [list "ERROR unit: [lindex [split $err "\n"] 0]"]
        catch {set_property top pipeline_tb [get_filesets sim_1]}
    }
    set n [llength $unitarios]
    set resumen [concat $resumen $lineas]
    lappend resumen "UNITARIOS: [expr {$n - [llength $fallas]}] de $n testbenches con TEST PASSED"
    incr fallas_total [llength $fallas]
}

catch {reset_simulation -simset sim_1 -mode behavioral}
update_compile_order -fileset sim_1

set f [open [file join $reg_dir resumen.txt] w]
puts $f [join $resumen "\n"]
close $f
puts [join $resumen "\n"]
if {$fallas_total > 0} {
    error "regresión: $fallas_total corridas o testbenches fallaron (logs en $log_dir)"
}
if {[llength $no_detectados] > 0 || [llength $con_error] > 0} {
    error "regresión: mutantes no detectados: [join $no_detectados {, }]; con ERROR: [join $con_error {, }] (logs en $log_dir)"
}
