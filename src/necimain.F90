! Copyright (c) 2013, Ali Alavi unless otherwise noted.
! This program is integrated in Molpro with the permission of George Booth and Ali Alavi
 


#ifdef CBINDMPI

    ! If calling from C, then we need to have an available fortran calling
    ! point available to the C-start point
    
    subroutine neci_main_c () bind(c)
        implicit none
        character(64) :: dummy1,dummy2

        write(6,*) 'STARTING NECI'
        dummy1=' '
        dummy2=' '
        ! Indicate not called by CPMD, VASP, Molpro
        call NECICore (0, .false., .false., .false.,dummy1,dummy2)

    end subroutine

#else

    ! necimain is the entry point for a standalone NECI.  It reads in an 
    ! input, and then runs the NECI Core
    program NECI
        implicit none
        character(64) :: dummy1,dummy2

        write(6,*) "STARTING NECI"
        dummy1=' '
        dummy2=' '
        ! Indicate not called by CPMD, VASP, Molpro
        call NECICore(0,.False.,.False.,.false.,dummy1,dummy2)

    end program NECI

#endif
