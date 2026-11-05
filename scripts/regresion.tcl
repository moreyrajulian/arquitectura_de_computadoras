# ---------------------------------------------------------------------------
# Regresión del pipeline en Vivado (decisión 028): corre pipeline_tb una vez por
# línea de build/regresion/corridas.txt, que escribe scripts/regresion.py.
#
#   python scripts/regresion.py [--modo sin_riesgos|forwarding|forwarding_stall|completo] [programas...]
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
#
# Con mutantes (regresion.py --mutante, decisión 031) corre la lista entera una vez
# por mutante: deshabilita el archivo original de rtl/ y simula con la copia de
# build/mutantes/, sin tocar rtl/. Los logs van a build/regresion/logs/<mutante>/.
# Lo que se espera es lo contrario: el script termina con error si algún mutante
# no hace fallar ninguna corrida. Al terminar, o si algo falla en el medio, el
# proyecto queda como estaba.
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

# Mutantes: nombre, archivo original y copia mutada (relativos a la raíz). Sin la
# lista, una sola pasada sin mutante ("")
set mut_list [file join $reg_dir mutantes.txt]
set mutantes [list ""]
if {[file exists $mut_list]} {
    set mutantes [list]
    set f [open $mut_list r]
    foreach linea [split [read $f] "\n"] {
        if {[string trim $linea] ne ""} { lappend mutantes $linea }
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

# Una pasada: todas las corridas, con los logs en dir. Devuelve {fallas lineas}
proc reg_pasada {corridas reg_root sim_dir dir} {
    set lineas [list]
    set fallas [list]
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
            lappend lineas "FALLA $etiqueta: [lindex [split $err "\n"] 0]"
            lappend fallas $etiqueta
            continue
        }
        if {![file exists $sim_log]} {
            lappend lineas "FALLA $etiqueta: xsim no dejó simulate.log"
            lappend fallas $etiqueta
            continue
        }

        set log [file join $dir $etiqueta.log]
        file copy -force $sim_log $log
        set res [reg_resultado $log]
        if {[string match "TEST PASSED*" $res]} {
            lappend lineas "ok    $etiqueta: $res"
        } else {
            if {$res eq ""} { set res "sin línea TEST" }
            lappend lineas "FALLA $etiqueta: $res"
            lappend fallas $etiqueta
        }
    }
    set_property -name {xsim.simulate.xsim.more_options} -value {} -objects [get_filesets sim_1]
    return [list $fallas $lineas]
}

set_property top pipeline_tb [get_filesets sim_1]
catch {close_sim -force}        ;# por si quedó abierta una simulación, por ejemplo de ondas.tcl

set resumen [list]
set fallas_total 0
set no_detectados [list]
foreach mutante $mutantes {
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
        lassign [reg_pasada $corridas $reg_root $sim_dir $dir] fallas lineas
    } err]} {
        set fallas [list error]
        set lineas [list "FALLA: [lindex [split $err "\n"] 0]"]
    }
    reg_restaurar

    set n [llength $corridas]
    if {$mutante eq ""} {
        set resumen [concat $resumen $lineas]
        lappend resumen "REGRESION: [expr {$n - [llength $fallas]}] de $n corridas con TEST PASSED"
        set fallas_total [llength $fallas]
    } elseif {[llength $fallas] > 0} {
        lappend resumen "MUTANTE $nombre: detectado, fallan [llength $fallas] de $n corridas: [join $fallas {, }]"
    } else {
        lappend resumen "MUTANTE $nombre: NO DETECTADO, $n de $n corridas con TEST PASSED"
        lappend no_detectados $nombre
    }
}
catch {reset_simulation -simset sim_1 -mode behavioral}
update_compile_order -fileset sim_1

set f [open [file join $reg_dir resumen.txt] w]
puts $f [join $resumen "\n"]
close $f
puts [join $resumen "\n"]
if {$fallas_total > 0} {
    error "regresión: $fallas_total corridas fallaron (logs en $log_dir)"
}
if {[llength $no_detectados] > 0} {
    error "regresión: mutantes no detectados: [join $no_detectados {, }] (logs en $log_dir)"
}
