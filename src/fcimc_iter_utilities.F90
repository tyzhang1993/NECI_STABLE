! Copyright (c) 2013, Ali Alavi unless otherwise noted.
! This program is integrated in Molpro with the permission of George Booth and Ali Alavi
 
#include "macros.h"
module fcimc_iter_utils

    use SystemData, only: nel, tHPHF, tNoBrillouin, tRef_Not_HF
    use CalcData, only: tSemiStochastic, tChangeProjEDet, tTrialWavefunction, &
                        tCheckHighestPopOnce, tRestartHighPop, StepsSft, tau, &
                        tTruncInitiator, tJumpShift, TargetGrowRate, tCCMC, &
                        tLetInitialPopDie, InitWalkers, tCheckHighestPop, &
                        HFPopThresh, DiagSft, tShiftOnHFPop, iRestartWalkNum, &
                        FracLargerDet, tKP_FCIQMC, MaxNoatHF, SftDamp, &
                        nShiftEquilSteps, TargetGrowRateWalk
    use LoggingData, only: tFCIMCStats2
    use semi_stoch_procs, only: recalc_core_hamil_diag
    use DetBitOps, only: TestClosedShellDet
    use bit_rep_data, only: NIfD, NIfTot, NIfDBO
    use Determinants, only: get_helement
    use hphf_integrals, only: hphf_diag_helement
    use global_det_data, only: set_det_diagH
    use tau_search, only: update_tau
    use Parallel_neci
    use fcimc_initialisation
    use fcimc_output
    use fcimc_helper
    use FciMCData
    use constants
    use util_mod
    implicit none

contains

    ! TODO: COMMENTING
    subroutine iter_diagnostics ()

        character(*), parameter :: this_routine = 'iter_diagnostics'
        character(*), parameter :: t_r = this_routine
        real(dp) :: mean_walkers
        integer :: part_type

        ! Update the total imaginary time passed
        TotImagTime = TotImagTime + StepsSft * Tau

        ! Set Iter time to equal the average time per iteration in the
        ! previous update cycle.
        IterTime = IterTime / real(StepsSft,sp)

        ! Calculate the acceptance ratio
        AccRat = real(Acceptances, dp) / SumWalkersCyc


#ifndef __CMPLX
        ! This is disabled for CCMC, as in CCMCStandalone then CurrentDets
        ! is not allocated.
        if (.not. tKP_FCIQMC .and. .not. tCCMC) then
            do part_type = 1, lenof_sign
                if ((.not.tFillingStochRDMonFly).or.(inum_runs.eq.1)) then
                    if (AllNoAtHF(part_type) < 0.0_dp) then
                        root_print 'No. at HF < 0 - flipping sign of entire ensemble &
                                   &of particles in simulation: ', part_type
                        root_print AllNoAtHF(part_type)

                        ! And do the flipping
                        call FlipSign(part_type)
                        AllNoatHF(part_type) = -AllNoatHF(part_type)
                        NoatHF(part_type) = -NoatHF(part_type)

                        if (tFillingStochRDMonFly) then
                            ! Want to flip all the averaged signs.
                            AvNoatHF = -AVNoatHF
                            InstNoatHF(part_type) = -InstNoatHF(part_type)
                        end if
                    endif
                end if
            end do
        end if
#endif

        if (iProcIndex == Root) then
            ! Have all of the particles died?
#ifdef __CMPLX
            if (AllTotwalkers == 0)  then
                write(iout,"(A)") "All particles have died. Restarting."
                tRestart=.true.
            else
                tRestart=.false.
            endif
#else
            if ((AllTotParts(1).eq.0).or.(AllTotParts(inum_runs).eq.0))  then
                write(iout,"(A)") "All particles have died. Restarting."
                tRestart=.true.
            else
                tRestart=.false.
            endif
            !TODO CMO: Work out how to wipe the walkers on the second population if double run
#endif
        endif
        call MPIBCast(tRestart)
        if(tRestart) then
!Initialise variables for calculation on each node
            Iter=1
            CALL DeallocFCIMCMemPar()
            IF(iProcIndex.eq.Root) THEN
                CLOSE(fcimcstats_unit)
                if (inum_runs.eq.2) CLOSE(fcimcstats_unit2)
                IF(tTruncInitiator) CLOSE(initiatorstats_unit)
                IF(tLogComplexPops) CLOSE(complexstats_unit)
            ENDIF
            IF(TDebug) CLOSE(11)
            CALL SetupParameters()
            CALL InitFCIMCCalcPar()
            if (tFCIMCStats2) then
                call write_fcimcstats2(iter_data_fciqmc, initial=.true.)
                call write_fcimcstats2(iter_data_fciqmc)
            else
                call WriteFciMCStatsHeader()
                ! Prepend a # to the initial status line so analysis doesn't pick up
                ! repetitions in the FCIMCStats or INITIATORStats files from restarts.
                if (iProcIndex == root) then
                    write (fcimcstats_unit,'("#")', advance='no')
                    if (inum_runs == 2) &
                        write(fcimcstats_unit2, '("#")', advance='no')
                    write (initiatorstats_unit,'("#")', advance='no')
                end if
                call WriteFCIMCStats()
            end if
            return
        endif

        if(iProcIndex.eq.Root) then
! AJWT dislikes doing this type of if based on a (seeminly unrelated) input option, but can't see another easy way.
!  TODO:  Something to make it better
            if(.not.tCCMC) then
               ! Check how balanced the load on each processor is (even though
               ! we cannot load balance with direct annihilation).
               WalkersDiffProc = int(MaxWalkersProc - MinWalkersProc,sizeof_int)
               ! Do the same for number of particles
               PartsDiffProc = int(MaxPartsProc - MinPartsProc, sizeof_int)

               mean_walkers = AllTotWalkers / real(nNodes,dp)
               if (WalkersDiffProc > nint(mean_walkers / 10.0_dp) .and. &
                   sum(AllTotParts) > real(nNodes * 500, dp)) then
                   root_write (iout, '(a, i13,a,2i11)') &
                       'Potential load-imbalance on iter ',iter + PreviousCycles,' Min/Max determinants on node: ', &
                       MinWalkersProc,MaxWalkersProc
               endif
            endif
        endif

    end subroutine iter_diagnostics

    subroutine population_check ()
        use HPHFRandExcitMod, only: ReturnAlphaOpenDet
        integer :: pop_highest, proc_highest
        real(dp) :: pop_change, old_Hii
        integer :: det(nel), i, error
        integer(int32) :: int_tmp(2)
        logical :: tSwapped
        HElement_t :: h_tmp

        if (tCheckHighestPop) then

            ! Obtain the determinant (and its processor) with the highest
            ! population. To keep this simple, do it only for set 1 if using double run,
            ! as we need to keep a consistent HF det for the two runs.
            call MPIAllReduceDatatype ((/int(iHighestPop,int32), int(iProcIndex,int32)/), 1, &
                                       MPI_MAXLOC, MPI_2INTEGER, int_tmp)
            pop_highest = int_tmp(1)
            proc_highest = int_tmp(2)

            ! NB: the use if int(iHighestPop) obviously introduces a small amount of error
            ! by ignoring the fractional population here

            ! How many walkers do we need to switch dets?
            
            ! If doing a double run, we only test population 1. abs_sign considers element 1
            ! unless we're running the complex code.
            if((lenof_sign.eq.2).and.(inum_runs.eq.1)) then 
                pop_change = FracLargerDet * abs_sign(AllNoAtHF)
            else
                pop_change = FracLargerDet * abs(AllNoAtHF(1))
            endif
!            write(iout,*) "***",AllNoAtHF,FracLargerDet,pop_change, pop_highest,proc_highest
            if (pop_change < pop_highest .and. pop_highest > 50) then

                ! Write out info!
                    root_print 'Highest weighted determinant not reference &
                               &det: ', pop_highest, abs_sign(AllNoAtHF)
                    

                ! Are we changing the reference determinant?
                if (tChangeProjEDet) then
                    ! Communicate the change to all dets and print out.
                    call MPIBcast (HighestPopDet(0:NIfTot), NIfTot+1, proc_highest)
                    iLutRef = 0
                    iLutRef(0:NIfDBO) = HighestPopDet(0:NIfDBO)
                    call decode_bit_det (ProjEDet, iLutRef)
                    write (iout, '(a)', advance='no') 'Changing projected &
                          &energy reference determinant for the next update cycle to: '
                    call write_det (iout, ProjEDet, .true.)
                    tRef_Not_HF = .true.

                    if(tHPHF) then
                        if(.not.TestClosedShellDet(iLutRef)) then
                            !Complications. We are now effectively projecting onto a LC of two dets.
                            !Ensure this is done correctly.
                            if(.not.Allocated(RefDetFlip)) then
                                allocate(RefDetFlip(NEl))
                                allocate(iLutRefFlip(0:NIfTot))
                                RefDetFlip = 0
                                iLutRefFlip = 0
                            endif
                            call ReturnAlphaOpenDet(ProjEDet,RefDetFlip,iLutRef,iLutRefFlip,.true.,.true.,tSwapped)
                            if(tSwapped) then
                                !The iLutRef should already be the correct one, since it was obtained by the normal calculation!
                                call stop_all("population_check","Error in changing reference determinant to open shell HPHF")
                            endif
                            write(iout,"(A)") "Now projecting onto open-shell HPHF as a linear combo of two determinants..."
                            tSpinCoupProjE=.true.
                        endif
                    else
                        tSpinCoupProjE=.false.  !In case it was already on, and is now projecting onto a CS HPHF.
                    endif

                    ! We can't use Brillouin's theorem if not a converged,
                    ! closed shell, ground state HF det.
                    tNoBrillouin = .true.
                    root_print "Ensuring that Brillouin's theorem is no &
                               &longer used."

                    ! Update the reference energy
                    old_Hii = Hii
                    if (tHPHF) then
                        h_tmp = hphf_diag_helement (ProjEDet, iLutRef)
                    else
                        h_tmp = get_helement (ProjEDet, ProjEDet, 0)
                    endif
                    Hii = real(h_tmp, dp)
                    write (iout, '(a, g25.15)') 'Reference energy now set to: ',&
                                             Hii

                    ! Reset averages
                    SumENum(:)=0
                    sum_proje_denominator(:) = 0
                    cyc_proje_denominator(:) = 0
                    SumNoatHF(:) = 0.0_dp
                    VaryShiftCycles(:) = 0
                    SumDiagSft(:) = 0
                    root_print 'Zeroing all energy estimators.'

                    !Since we have a new reference, we must block only from after this point
                    iBlockingIter = Iter + PreviousCycles

                    ! Regenerate all the diagonal elements relative to the
                    ! new reference det.
                    write (iout,*) 'Regenerating the stored diagonal HElements &
                                &for all walkers.'
                    do i = 1, int(Totwalkers,sizeof_int)
                        call decode_bit_det (det, CurrentDets(:,i))
                        if (tHPHF) then
                            h_tmp = hphf_diag_helement (det, CurrentDets(:,i))
                        else
                            h_tmp = get_helement (det, det, 0)
                        endif
                        call set_det_diagH(i, real(h_tmp, dp) - Hii)
                    enddo
                    if (tSemiStochastic) call recalc_core_hamil_diag(old_Hii, Hii)

                    ! Reset values introduced in soft_exit (CHANGEVARS)
                    if (tCHeckHighestPopOnce) then
                        tChangeProjEDet = .false.
                        tCheckHighestPop = .false.
                        tCheckHighestPopOnce = .false.
                    endif

                ! Or are we restarting the calculation with the reference 
                ! det switched?
#ifdef __CMPLX
                elseif (tRestartHighPop .and. &
                        iRestartWalkNum < sum(AllTotParts)) then
#else
                elseif (tRestartHighPop .and. &
                        iRestartWalkNum < AllTotParts(1)) then
#endif
                    
                    ! Broadcast the changed det to all processors
                    call MPIBcast (HighestPopDet, NIfTot+1, proc_highest)
                    iLutRef = 0
                    iLutRef(0:NIfDBO) = HighestPopDet(0:NIfDBO)
                    tRef_Not_HF = .true.

                    call decode_bit_det (ProjEDet, iLutRef)
                    write (iout, '(a)', advance='no') 'Changing projected &
                             &energy reference determinant to: '
                    call write_det (iout, ProjEDet, .true.)

                    ! We can't use Brillouin's theorem if not a converged,
                    ! closed shell, ground state HF det.
                    tNoBrillouin = .true.
                    root_print "Ensuring that Brillouin's theorem is no &
                               &longer used."
                    
                    ! Update the reference energy
                    if (tHPHF) then
                        h_tmp = hphf_diag_helement (ProjEDet, iLutRef)
                    else
                        h_tmp = get_helement (ProjEDet, ProjEDet, 0)
                    endif
                    Hii = real(h_tmp, dp)
                    write (iout, '(a, g25.15)') 'Reference energy now set to: ',&
                                             Hii

                    ! Reset values introduced in soft_exit (CHANGEVARS)
                    if (tCHeckHighestPopOnce) then
                        tChangeProjEDet = .false.
                        tCheckHighestPop = .false.
                        tCheckHighestPopOnce = .false.
                    endif

                    call ChangeRefDet (ProjEDet)
                endif

            endif
        endif
                    
    end subroutine

    subroutine collate_iter_data (iter_data, tot_parts_new, tot_parts_new_all)
        integer :: int_tmp(5+2*lenof_sign), proc, pos, i
        real(dp) :: sgn(lenof_sign)
        HElement_t :: helem_tmp(3*inum_runs)
        HElement_t :: real_tmp(2*inum_runs) !*lenof_sign
        integer(int64) :: int64_tmp(8),TotWalkersTemp
        type(fcimc_iter_data) :: iter_data
        real(dp), dimension(lenof_sign), intent(in) :: tot_parts_new
        real(dp), dimension(lenof_sign), intent(out) :: tot_parts_new_all
        character(len=*), parameter :: this_routine='collate_iter_data'
        real(dp), dimension(max(lenof_sign,inum_runs)) :: RealAllHFCyc
        real(dp), dimension(inum_runs) :: all_norm_psi_squared, all_norm_semistoch_squared
        real(dp) :: bloom_sz_tmp(0:2)
        integer :: run
    
        ! Communicate the integers needing summation

        call MPIReduce(SpawnFromSing, MPI_SUM, AllSpawnFromSing)
        call MPIReduce(iter_data%update_growth, MPI_SUM, iter_data%update_growth_tot)
        call MPIReduce(NoBorn, MPI_SUM, AllNoBorn)
        call MPIReduce(NoDied, MPI_SUM, AllNoDied)
        call MPIReduce(HFCyc, MPI_SUM, RealAllHFCyc)
        call MPIReduce(NoAtDoubs, MPI_SUM, AllNoAtDoubs)
        call MPIReduce(Annihilated, MPI_SUM, AllAnnihilated)
        
        do run=1,inum_runs
            AllHFCyc(run)=ARR_RE_OR_CPLX(RealAllHFCyc,run)
        enddo
        
        ! Integer summations required for the initiator method
        if (tTruncInitiator) then
            call MPISum ((/NoAddedInitiators(1), NoInitDets(1), &
                           NoNonInitDets(1), NoExtraInitdoubs(1), InitRemoved(1)/),&
                          int64_tmp(1:5))
            AllNoAddedInitiators(1) = int64_tmp(1)
            AllNoInitDets(1) = int64_tmp(2)
            AllNoNonInitDets(1) = int64_tmp(3)
            AllNoExtraInitDoubs(1) = int64_tmp(4)
            AllInitRemoved(1) = int64_tmp(5)

            call MPIReduce(NoAborted, MPI_SUM, AllNoAborted)
            call MPIReduce(NoRemoved, MPI_SUM, AllNoRemoved)
            call MPIReduce(NoNonInitWalk, MPI_SUM, AllNoNonInitWalk)
            call MPIReduce(NoInitWalk, MPI_SUM, AllNoInitWalk)
        endif

        ! 64bit integers
        !Remove the holes in the main list when wanting the number of uniquely occupied determinants
        !this should only change the number for tHashWalkerList
        TotWalkersTemp=TotWalkers-HolesInList
        call MPIReduce(TotwalkersTemp, MPI_SUM, AllTotWalkers)
        call MPIReduce(norm_psi_squared,MPI_SUM,all_norm_psi_squared)
        call MPIReduce(norm_semistoch_squared,MPI_SUM,all_norm_semistoch_squared)
        call MPIReduce(Totparts,MPI_SUM,AllTotParts)
        call MPIReduce(tot_parts_new,MPI_SUM,tot_parts_new_all)
#ifdef __CMPLX
        norm_psi = sqrt(sum(all_norm_psi_squared))
        norm_semistoch = sqrt(sum(all_norm_semistoch_squared))
#else
        norm_psi = sqrt(all_norm_psi_squared)
        norm_semistoch = sqrt(all_norm_semistoch_squared)
#endif
        
        call MPIReduce(SumNoatHF, MPI_SUM, AllSumNoAtHF)
        ! HElement_t values (Calculates the energy by summing all on HF and 
        ! doubles)

        call MPISum ((/ENumCyc, SumENum, ENumCycAbs/), helem_tmp)
        AllENumCyc(:) = helem_tmp(1:inum_runs)
        AllSumENum(:) = helem_tmp(1+inum_runs:2*inum_runs)
        AllENumCycAbs(:) = helem_tmp(1+2*inum_runs:3*inum_runs)
        
        ! Deal with particle blooms
!        if (tSpinProjDets) then
!            call MPISum(bloom_count(0:2), all_bloom_count(0:2))
!            call MPIReduce_inplace(bloom_sizes(0:2), MPI_MAX)
!        else
            call MPISum(bloom_count(1:2), all_bloom_count(1:2))
            call MPIReduce(bloom_sizes(1:2), MPI_MAX, bloom_sz_tmp(1:2))
            bloom_sizes(1:2) = bloom_sz_tmp(1:2)
!        end if

        ! real(dp) values
        call MPISum((/cyc_proje_denominator, sum_proje_denominator/),real_tmp)
        all_cyc_proje_denominator = real_tmp(1:inum_runs)!(1:lenof_sign)
        all_sum_proje_denominator = real_tmp(1+inum_runs:2*inum_runs)!(lenof_sign+1:2*lenof_sign)

        ! Max/Min values (check load balancing)
        call MPIReduce (TotWalkersTemp, MPI_MAX, MaxWalkersProc)
        call MPIReduce (TotWalkersTemp, MPI_MIN, MinWalkersProc)
        call MPIReduce (max_cyc_spawn, MPI_MAX, all_max_cyc_spawn)
        !call MPIReduce (sum(TotParts), MPI_MAX, MaxPartsProc)
        !call MPIReduce (sum(TotParts), MPI_MIN, MinPartsProc)

        ! We need the total number on the HF and SumWalkersCyc to be valid on
        ! ALL processors (Both double precision reals)
        call MPISumAll (NoatHF, AllNoatHF)
        call MPISumAll (SumWalkersCyc, AllSumWalkersCyc)

        !        WRITE(iout,*) "***",iter_data%update_growth_tot,AllTotParts-AllTotPartsOld

        if (tSearchTau .and. (.not. tFillingStochRDMonFly)) &
            call update_tau()

        !TODO CMO:Make sure these are length 2 as well
        if (tTrialWavefunction) then
            call MPIAllReduce(trial_numerator, MPI_SUM, tot_trial_numerator)
            call MPIAllReduce(trial_denom, MPI_SUM, tot_trial_denom)
        end if
        
#ifdef __DEBUG
        !Write this 'ASSERTROOT' out explicitly to avoid line lengths problems
        if ((iProcIndex == root) .and. .not. tSpinProject .and. &
         all(abs(iter_data%update_growth_tot-(AllTotParts-AllTotPartsOld)) > 1.0e-5)) then
            write(iout,*) "update_growth: ",iter_data%update_growth_tot
            write(iout,*) "AllTotParts: ",AllTotParts
            write(iout,*) "AllTotPartsOld: ", AllTotPartsOld
            call stop_all (this_routine, &
                "Assertation failed: all(iter_data%update_growth_tot.eq.AllTotParts-AllTotPartsOld)")
        endif
#endif
    
    end subroutine collate_iter_data

    subroutine update_shift (iter_data)
        use CalcData, only : tInstGrowthRate
     
        type(fcimc_iter_data), intent(in) :: iter_data
        integer(int64) :: tot_walkers
        logical, dimension(inum_runs) :: tReZeroShift
        real(dp) :: AllGrowRateRe, AllGrowRateIm
        real(dp), dimension(inum_runs)  :: AllHFGrowRate
        real(dp), dimension(lenof_sign) :: denominator, all_denominator
        integer :: error, i, proc, pos, run
        logical, dimension(inum_runs) :: defer_update
        logical :: start_varying_shift

        ! Normally we allow the shift to vary depending on the conditions
        ! tested. Sometimes we want to defer this to the next cycle...
        defer_update(:) = .false.

!        call neci_flush(iout)
!        CALL MPIBarrier(error)

        ! collate_iter_data --> The values used are only valid on Root
        if (iProcIndex == Root) then
            ! Calculate the growth rate
!            WRITE(iout,*) "iter_data%nborn: ",iter_data%nborn(:)
!            WRITE(iout,*) "iter_data%ndied: ",iter_data%ndied(:)
!            WRITE(iout,*) "iter_data%nannihil: ",iter_data%nannihil(:)
!            WRITE(iout,*) "iter_data%naborted: ",iter_data%naborted(:)
!            WRITE(iout,*) "iter_data%update_growth: ",iter_data%update_growth(:)
!            WRITE(iout,*) "iter_data%update_growth_tot: ",iter_data%update_growth_tot(:)
!            WRITE(iout,*) "iter_data%tot_parts_old: ",iter_data%tot_parts_old(:)
!            WRITE(iout,*) "iter_data%update_iters: ",iter_data%update_iters
!            CALL neci_flush(iout)


            if(tInstGrowthRate) then
!Calculate the growth rate simply using the two points at the beginning and the
!end of the update cycle. 
                if ((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                    !COMPLEX
                    AllGrowRate = (sum(iter_data%update_growth_tot &
                               + iter_data%tot_parts_old)) &
                              / real(sum(iter_data%tot_parts_old), dp)
                else
                    do run=1,inum_runs
                        AllGrowRate(run) = (iter_data%update_growth_tot(run) &
                                   + iter_data%tot_parts_old(run)) &
                                  / real(iter_data%tot_parts_old(run), dp)
                    enddo
                endif
            else
!Instead attempt to calculate the average growth over every iteration
!over the update cycle
                if ((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                    !COMPLEX
                    AllGrowRate = (sum(AllSumWalkersCyc)/real(StepsSft,dp)) &
                                    /sum(OldAllAvWalkersCyc)
                else

                    do run=1,inum_runs
                        AllGrowRate(run) = (AllSumWalkersCyc(run)/real(StepsSft,dp)) &
                                        /OldAllAvWalkersCyc(run)
                    enddo
                endif
            endif

            ! For complex case, obtain both Re and Im parts
            if ((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                IF(iter_data%tot_parts_old(1).gt.0) THEN
                    AllGrowRateRe = (iter_data%update_growth_tot(1) + &
                                     iter_data%tot_parts_old(1)) / &
                                     iter_data%tot_parts_old(1)
                ENDIF
                IF(iter_data%tot_parts_old(lenof_sign).gt.0) THEN
                    AllGrowRateIm = (iter_data%update_growth_tot(lenof_sign) + &
                                         iter_data%tot_parts_old(lenof_sign)) / &
                                         iter_data%tot_parts_old(lenof_sign)
                ENDIF
            endif

!AJWT commented this out as DMC says it's not being used, and it gave a divide by zero
            ! Initiator abort growth rate
!            if (tTruncInitiator) then
!                AllGrowRateAbort = (sum(iter_data%update_growth_tot + &
!                                    iter_data%tot_parts_old) + AllNoAborted) &
!                                    / (sum(iter_data%tot_parts_old) &
!                                       + AllNoAbortedOld)
!            endif

            ! Exit the single particle phase if the number of walkers exceeds
            ! the value in the input file. If particle no has fallen, re-enter
            ! it.
            tReZeroShift = .false.
            do run=1,inum_runs
                if (TSinglePartPhase(run)) then
    ! AJWT dislikes doing this type of if based on a (seeminly unrelated) input option, but can't see another easy way.
    !  TODO:  Something to make it better
                    if(.not.tCCMC) then
                        tot_walkers = InitWalkers * int(nNodes,int64)
                    else
                        tot_walkers = InitWalkers
                    endif

#ifdef __CMPLX
                    if ((sum(AllTotParts) > tot_walkers) .or. &
                         (abs_sign(AllNoatHF) > MaxNoatHF)) then
    !                     WRITE(iout,*) "AllTotParts: ",AllTotParts(1),AllTotParts(2),tot_walkers
                        write (iout, '(a,i13,a)') 'Exiting the single particle growth phase on iteration: ',iter + PreviousCycles, &
                                     ' - Shift can now change'
                        VaryShiftIter = Iter
                        iBlockingIter = Iter + PreviousCycles
                        tSinglePartPhase = .false.
                        if(TargetGrowRate(1).ne.0.0_dp) then
                            write(iout,"(A)") "Setting target growth rate to 1."
                            TargetGrowRate=0.0_dp
                        endif

                        ! If enabled, jump the shift to the value preducted by the
                        ! projected energy!
                        if (tJumpShift) then
                            DiagSft = real(proje_iter,dp)
                            defer_update = .true.
                        end if
                    elseif (abs_sign(AllNoatHF) < (MaxNoatHF - HFPopThresh)) then
                        write (iout, '(a,i13,a)') 'No at HF has fallen too low - reentering the &
                                     &single particle growth phase on iteration',iter + PreviousCycles,' - particle number &
                                     &may grow again.'
                        tSinglePartPhase = .true.
                        tReZeroShift = .true.
                    endif
#else
                    start_varying_shift = .false.
                    if (tLetInitialPopDie) then
                        if (AllTotParts(run) < tot_walkers) start_varying_shift = .true.
                    else
                        if ((AllTotParts(run) > tot_walkers) .or. &
                             (abs(AllNoatHF(run)) > MaxNoatHF)) start_varying_shift = .true.
                    end if

                    if (start_varying_shift) then
    !                     WRITE(iout,*) "AllTotParts: ",AllTotParts(1),AllTotParts(2),tot_walkers
                        write (iout, '(a,i13,a,i1)') 'Exiting the single particle growth phase on iteration: ' &
                                     ,iter + PreviousCycles, ' - Shift can now change for population', run
                        VaryShiftIter(run) = Iter
                        iBlockingIter(run) = Iter + PreviousCycles
                        tSinglePartPhase(run) = .false.
                        if(TargetGrowRate(run).ne.0.0_dp) then
                            write(iout,"(A)") "Setting target growth rate to 1."
                            TargetGrowRate(run)=0.0_dp
                        endif

                        ! If enabled, jump the shift to the value preducted by the
                        ! projected energy!
                        if (tJumpShift) then
                            DiagSft(run) = real(proje_iter(run),dp)
                            defer_update(run) = .true.
                        end if
                    elseif (abs(AllNoatHF(run)) < (MaxNoatHF - HFPopThresh)) then
                        write (iout, '(a,i13,a)') 'No at HF has fallen too low - reentering the &
                                     &single particle growth phase on iteration',iter + PreviousCycles,' - particle number &
                                     &may grow again.'
                        tSinglePartPhase(run) = .true.
                        tReZeroShift(run) = .true.
                    endif
#endif
                endif
                ! How should the shift change for the entire ensemble of walkers 
                ! over all processors.
                if (((.not. tSinglePartPhase(run)).or.(TargetGrowRate(run).ne.0.0_dp)) .and.&
                    .not. defer_update(run)) then

                    !In case we want to continue growing, TargetGrowRate > 0.0_dp
                    ! New shift value
                    if(TargetGrowRate(run).ne.0.0_dp) then
                        if((lenof_sign.eq.2).and.(inum_runs.eq.1))then
                        
                            if(sum(AllTotParts).gt.TargetGrowRateWalk(1)) then
                                !Only allow targetgrowrate to kick in once we have > TargetGrowRateWalk walkers.
                                DiagSft = DiagSft - (log(AllGrowRate-TargetGrowRate) * SftDamp) / &
                                                    (Tau * StepsSft)
                            endif
                        else
                            if(AllTotParts(run).gt.TargetGrowRateWalk(run)) then
                                !Only allow targetgrowrate to kick in once we have > TargetGrowRateWalk walkers.
                                DiagSft(run) = DiagSft(run) - (log(AllGrowRate(run)-TargetGrowRate(run)) * SftDamp) / &
                                                    (Tau * StepsSft)
                            endif
                        endif
                    else
                        if(tShiftonHFPop) then
                            !Calculate the shift required to keep the HF population constant

                            AllHFGrowRate(run) = abs(AllHFCyc(run)/real(StepsSft,dp)) / abs(OldAllHFCyc(run))

                            DiagSft(run) = DiagSft(run) - (log(AllHFGrowRate(run)) * SftDamp) / &
                                                (Tau * StepsSft)
                        else
                            !"WRITE(6,*) "AllGrowRate, TargetGrowRate", AllGrowRate, TargetGrowRate
                            DiagSft(run) = DiagSft(run) - (log(AllGrowRate(run)) * SftDamp) / &
                                                (Tau * StepsSft)
                        endif
                    endif

                    if ((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                        !COMPLEX
                        DiagSftRe = DiagSftRe - (log(AllGrowRateRe-TargetGrowRate(1)) * SftDamp) / &
                                                (Tau * StepsSft)
                        DiagSftIm = DiagSftIm - (log(AllGrowRateIm-TargetGrowRate(1)) * SftDamp) / &
                                                (Tau * StepsSft)
                    endif

                    ! Update the shift averages
                    if ((iter - VaryShiftIter(run)) >= nShiftEquilSteps) then
                        if ((iter-VaryShiftIter(run)-nShiftEquilSteps) < StepsSft) &
                            write (iout, '(a,i14)') 'Beginning to average shift value on iteration: ',iter + PreviousCycles
                        VaryShiftCycles(run) = VaryShiftCycles(run) + 1
                        SumDiagSft(run) = SumDiagSft(run) + DiagSft(run)
                        AvDiagSft(run) = SumDiagSft(run) / real(VaryShiftCycles(run), dp)
                    endif

    !                ! Update DiagSftAbort for initiator algorithm
    !                if (tTruncInitiator) then
    !                    DiagSftAbort = DiagSftAbort - &
    !                              (log(real(AllGrowRateAbort-TargetGrowRate, dp)) * SftDamp) / &
    !                              (Tau * StepsSft)
    !
    !                    if (iter - VaryShiftIter >= nShiftEquilSteps) then
    !                        SumDiagSftAbort = SumDiagSftAbort + DiagSftAbort
    !                        AvDiagSftAbort = SumDiagSftAbort / &
    !                                         real(VaryShiftCycles, dp)
    !                    endif
    !                endif
                endif
                if((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                    ! Calculate the instantaneous 'shift' from the HF population
                    HFShift(run) = -1.0_dp / abs_sign(AllNoatHF) * &
                                        (abs_sign(AllNoatHF) - abs_sign(OldAllNoatHF) / &
                                      (Tau * real(StepsSft, dp)))
                    InstShift(run) = -1.0_dp / sum(AllTotParts) * &
                                ((sum(AllTotParts) - sum(AllTotPartsOld)) / &
                                 (Tau * real(StepsSft, dp)))
                 else
                    ! Calculate the instantaneous 'shift' from the HF population
                    HFShift(run) = -1.0_dp / abs(AllNoatHF(run)) * &
                                        (abs(AllNoatHF(run)) - abs(OldAllNoatHF(run)) / &
                                      (Tau * real(StepsSft, dp)))
                    InstShift(run) = -1.0_dp / AllTotParts(run) * &
                                ((AllTotParts(run) - AllTotPartsOld(run)) / &
                                 (Tau * real(StepsSft, dp)))
                 endif

                 ! When using a linear combination, the denominator is summed
                 ! directly.
                 all_sum_proje_denominator(run) = ARR_RE_OR_CPLX(AllSumNoatHF,run)
                 all_cyc_proje_denominator(run) = AllHFCyc(run)

                 ! Calculate the projected energy.
                 if((lenof_sign.eq.2).and.(inum_runs.eq.1)) then
                     if (any(AllSumNoatHF /= 0.0)) then
                         ProjectionE = (AllSumENum) / (all_sum_proje_denominator) 
                         proje_iter = (AllENumCyc) / (all_cyc_proje_denominator) 
                        AbsProjE = (AllENumCycAbs) / (all_cyc_proje_denominator)
                    endif
                 else
                     if ((AllSumNoatHF(run) /= 0.0)) then
                         ProjectionE(run) = (AllSumENum(run)) / (all_sum_proje_denominator(run)) 
                         proje_iter(run) = (AllENumCyc(run)) / (all_cyc_proje_denominator(run)) 
                        AbsProjE(run) = (AllENumCycAbs(run)) / (all_cyc_proje_denominator(run))
                    endif
                endif
                ! If we are re-zeroing the shift
                if (tReZeroShift(run)) then
                    DiagSft(run) = 0
                    VaryShiftCycles(run) = 0
                    SumDiagSft(run) = 0
                    AvDiagSft(run) = 0
                endif
            enddo

            ! Get some totalled values
#ifdef __CMPLX
            projectionE_tot = ProjectionE(1)
            proje_iter_tot = proje_iter(1)
#else
            projectionE_tot = sum(AllSumENum(1:inum_runs)) &
                            / sum(all_sum_proje_denominator(1:inum_runs))
            proje_iter_tot = sum(AllENumCyc(1:inum_runs)) &
                           / sum(all_cyc_proje_denominator(1:inum_runs))
#endif

        endif ! iProcIndex == root

        ! Broadcast the shift from root to all the other processors
        call MPIBcast (tSinglePartPhase)
        call MPIBcast (VaryShiftIter)
        call MPIBcast (DiagSft)
        
        do run=1,inum_runs
            if(.not.tSinglePartPhase(run)) then
                TargetGrowRate(run)=0.0_dp
                tSearchTau=.false.
            endif
        enddo

    end subroutine update_shift 



    subroutine rezero_iter_stats_update_cycle (iter_data, tot_parts_new_all)
        
        type(fcimc_iter_data), intent(inout) :: iter_data
        real(dp), dimension(lenof_sign), intent(in) :: tot_parts_new_all
        
        ! Zero all of the variables which accumulate for each iteration.

        IterTime = 0.0
        SumWalkersCyc(:)=0.0_dp
        Annihilated = 0
        Acceptances = 0
        NoBorn = 0
        SpawnFromSing = 0
        NoDied = 0
        ENumCyc = 0
        ENumCycAbs = 0
        HFCyc = 0.0_dp
        cyc_proje_denominator=0
        trial_numerator = 0.0_dp
        trial_denom = 0.0_dp

        ! Reset TotWalkersOld so that it is the number of walkers now
        TotWalkersOld = TotWalkers
        TotPartsOld = TotParts

        ! Save the number at HF to use in the HFShift
        OldAllNoatHF = AllNoatHF
        !OldAllHFCyc is the average HF value for this update cycle
        OldAllHFCyc = AllHFCyc/real(StepsSft,dp)
        !OldAllAvWalkersCyc gives the average number of walkers per iteration in the last update cycle
      !TODO CMO: are these summed across real/complex? 
        OldAllAvWalkersCyc = AllSumWalkersCyc/real(StepsSft,dp)

        ! Also the cumulative global variables
        AllTotWalkersOld = AllTotWalkers
        AllTotPartsOld = AllTotParts
        AllNoAbortedOld = AllNoAborted


        ! Reset the counters
        iter_data%update_growth = 0.0_dp
        iter_data%update_iters = 0
        iter_data%tot_parts_old = tot_parts_new_all

        max_cyc_spawn = 0

    end subroutine

    subroutine calculate_new_shift_wrapper (iter_data, tot_parts_new)

        type(fcimc_iter_data), intent(inout) :: iter_data
        real(dp), dimension(lenof_sign), intent(in) :: tot_parts_new
        real(dp), dimension(lenof_sign) :: tot_parts_new_all

        call collate_iter_data (iter_data, tot_parts_new, tot_parts_new_all)
        call iter_diagnostics ()
        if(tRestart) return
        call population_check ()
        call update_shift (iter_data)
        if (tFCIMCStats2) then
            call write_fcimcstats2(iter_data_fciqmc)
        else
            call WriteFCIMCStats ()
        end if
        
        call rezero_iter_stats_update_cycle (iter_data, tot_parts_new_all)

    end subroutine calculate_new_shift_wrapper

    subroutine update_iter_data(iter_data)

        type(fcimc_iter_data), intent(inout) :: iter_data

        iter_data%update_growth = iter_data%update_growth + iter_data%nborn &
                                - iter_data%ndied - iter_data%nannihil &
                                - iter_data%naborted - iter_data%nremoved
        iter_data%update_iters = iter_data%update_iters + 1

    end subroutine update_iter_data


end module
