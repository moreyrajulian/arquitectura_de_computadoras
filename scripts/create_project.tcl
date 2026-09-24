# ---------------------------------------------------------------------------
# Crea el proyecto Vivado desde las fuentes del repo. El .xpr NO se versiona
# (guarda rutas absolutas y genera conflictos en cada merge); se regenera con esto.
#
# Desde la GUI de Vivado:
#   Tools > Run Tcl Script...  y elegir este archivo
#   o, en la Tcl Console:
#       set DESIGN tp2_uart
#       source <ruta-al-repo>/scripts/create_project.tcl
#
# Si no se define DESIGN, se usa riscv_basys3.
# El proyecto se crea en <repo>/build/vivado_<DESIGN> (carpeta ignorada por git).
# ---------------------------------------------------------------------------
if {![info exists DESIGN]} { set DESIGN riscv_basys3 }

set root     [file normalize [file join [file dirname [info script]] ..]]
set fpga_dir [file join $root fpga $DESIGN]
set proj_dir [file join $root build vivado_$DESIGN]
set part     xc7a35tcpg236-1   ;# Basys 3

if {![file isdirectory $fpga_dir]} {
    error "No existe $fpga_dir. Diseños disponibles: [glob -tails -directory [file join $root fpga] *]"
}

create_project -force $DESIGN $proj_dir -part $part

# RTL compartido (agrega rtl/ recursivamente)
add_files [file join $root rtl]

# Top y módulos propios del diseño
set srcs [glob -nocomplain [file join $fpga_dir *.v]]
if {[llength $srcs] > 0} { add_files -norecurse $srcs }

# Constraints
set xdcs [glob -nocomplain [file join $fpga_dir *.xdc]]
if {[llength $xdcs] > 0} { add_files -fileset constrs_1 -norecurse $xdcs }

# Testbenches (solo simulación)
set tbs [glob -nocomplain [file join $root tb unit *.v] [file join $root tb integration *.v]]
if {[llength $tbs] > 0} { add_files -fileset sim_1 -norecurse $tbs }

# IP cores (Clock Wizard, BRAM, ...): cada ip/*.tcl los genera con create_ip
foreach ip_script [lsort [glob -nocomplain [file join $root ip *.tcl]]] {
    puts "Generando IP: $ip_script"
    source $ip_script
}

set_property top top [current_fileset]
update_compile_order -fileset sources_1
puts "Proyecto listo en $proj_dir"
