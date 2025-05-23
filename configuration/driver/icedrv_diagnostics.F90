!=======================================================================

! Diagnostic information output during run
!
! authors: Elizabeth C. Hunke, LANL

      module icedrv_diagnostics

      use icedrv_kinds
      use icedrv_constants, only: nu_diag, nu_diag_out
      use icedrv_domain_size, only: nx, ncat
      use icedrv_domain_size, only: ncat, nfsd, n_iso, nilyr, nslyr
      use icepack_intfc, only: c0, c1
      use icepack_intfc, only: icepack_warnings_flush, icepack_warnings_aborted
      use icepack_intfc, only: icepack_query_parameters
      use icepack_intfc, only: icepack_query_tracer_flags, icepack_query_tracer_indices
      use icedrv_system, only: icedrv_system_abort, icedrv_system_flush

      implicit none
      private
      public :: runtime_diags, &
                init_mass_diags, &
                icedrv_diagnostics_debug, &
                print_state

      ! diagnostic output file
      character (len=char_len), public :: diag_file

      ! point print data

      logical (kind=log_kind), public :: &
         print_points         ! if true, print point data

      integer (kind=int_kind), parameter, public :: &
         npnt = 2             ! total number of points to be printed

      character (len=char_len), dimension(nx), public :: nx_names

      ! for water and heat budgets
      real (kind=dbl_kind), dimension(nx) :: &
         pdhi             , & ! change in mean ice thickness (m)
         pdhs             , & ! change in mean snow thickness (m)
         pde                  ! change in ice and snow energy (W m-2)

      real (kind=dbl_kind), dimension(nx,n_iso) :: &
         pdiso                ! change in mean isotope concentration

!=======================================================================

      contains

!=======================================================================

! Writes diagnostic info (max, min, global sums, etc) to standard out
!
! authors: Elizabeth C. Hunke, LANL
!          Bruce P. Briegleb, NCAR
!          Cecilia M. Bitz, UW

      subroutine runtime_diags (dt)

      use icedrv_arrays_column, only: floe_rad_c
      use icedrv_flux, only: evap, fsnow, frazil
      use icedrv_flux, only: fswabs, flw, flwout, fsens, fsurf, flat
      use icedrv_flux, only: frain, fiso_evap, fiso_ocn, fiso_atm
      use icedrv_flux, only: Tair, Qa, fsw, fcondtop, fcondbot
      use icedrv_flux, only: meltt, meltb, meltl, snoice
      use icedrv_flux, only: dsnow, congel, sst, sss, Tf, fhocn, albpnd, pump_amnt
      use icedrv_state, only: aice, vice, vsno, trcr, trcrn, aicen, vsnon

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      integer (kind=int_kind) :: &
         n, i

      logical (kind=log_kind) :: &
         calc_Tsfc, snwgrain

      character (len=char_len) :: &
         snwredist

      ! fields at diagnostic points
      real (kind=dbl_kind) :: &
         pTair, pfsnow, pfrain, &
         paice, hiavg, hsavg, hbravg, psalt, pTsfc, &
         pevap, pfhocn, hpnd, apnd, spnd, darcyavg, hocnavg, perm_harmavg, &
         rsnwavg, rhosavg, smicetot, smliqtot, smtot

      real (kind=dbl_kind), dimension (nx) :: &
         work1, work2, work3, work4, work5, work6

      real (kind=dbl_kind) :: &
         Tffresh, rhos, rhow, rhoi, ice_mass

      logical (kind=log_kind) :: tr_brine, tr_fsd, tr_iso, tr_snow
      integer (kind=int_kind) :: nt_fbri, nt_Tsfc, nt_fsd, nt_isosno, nt_isoice, nt_apnd
      integer (kind=int_kind) :: nt_rsnw, nt_rhos, nt_smice, nt_smliq, nt_hpnd

      character(len=*), parameter :: subname='(runtime_diags)'

      !-----------------------------------------------------------------
      ! query Icepack values
      !-----------------------------------------------------------------

      call icepack_query_parameters(calc_Tsfc_out=calc_Tsfc, &
           snwredist_out=snwredist, snwgrain_out=snwgrain)
      call icepack_query_tracer_flags(tr_brine_out=tr_brine, &
           tr_fsd_out=tr_fsd,tr_iso_out=tr_iso,tr_snow_out=tr_snow)
      call icepack_query_tracer_indices(nt_fbri_out=nt_fbri, nt_Tsfc_out=nt_Tsfc,&
           nt_fsd_out=nt_fsd, nt_isosno_out=nt_isosno, nt_isoice_out=nt_isoice, &
           nt_rsnw_out=nt_rsnw, nt_rhos_out=nt_rhos, &
           nt_smice_out=nt_smice, nt_smliq_out=nt_smliq, nt_hpnd_out=nt_hpnd, nt_apnd_out=nt_apnd)
      call icepack_query_parameters(Tffresh_out=Tffresh, rhos_out=rhos, &
           rhow_out=rhow, rhoi_out=rhoi)
      call icepack_warnings_flush(nu_diag)
      if (icepack_warnings_aborted()) call icedrv_system_abort(string=subname, &
          file=__FILE__,line= __LINE__)

      !-----------------------------------------------------------------
      ! NOTE these are computed for the last timestep only (not avg)
      !-----------------------------------------------------------------

      call total_energy (work1)
      call total_salt   (work2)
      call total_darcy  (work3)
      call total_spond  (work4)
      call total_hocn   (work5)
      call total_perm_harm(work6)

      do n = 1, nx
        pTair = Tair(n) - Tffresh ! air temperature
        pfsnow = fsnow(n)*dt/rhos ! snowfall
        pfrain = frain(n)*dt/rhow ! rainfall

        paice = aice(n)           ! ice area
        hiavg = c0                ! avg ice thickness
        hsavg = c0                ! avg snow thickness
        fsdavg = c0               ! FSD rep radius
        hbravg = c0               ! avg brine thickness
        rsnwavg = c0              ! avg snow grain radius
        rhosavg = c0              ! avg snow density
        smicetot = c0             ! total mass of ice in snow (kg/m2)
        smliqtot = c0             ! total mass of liquid in snow (kg/m2)
        smtot = c0                ! total mass of snow volume (kg/m2)
        psalt = c0
        spnd = c0
        darcyavg = c0
        hocnavg = c0
        perm_harmavg = c0
        if (paice /= c0) then
           hiavg = vice(n)/paice
           hsavg = vsno(n)/paice
           if (tr_brine) hbravg = trcr(n,nt_fbri) * hiavg
           if (tr_fsd) then        ! avg floe size distribution
              do nc = 1, ncat
              do k = 1, nfsd
                  fsdavg  = fsdavg &
                          + trcrn(n,nt_fsd+k-1,nc) * floe_rad_c(k) &
                          * aicen(n,nc) / paice
              end do
              end do
           end if
           if (tr_snow) then      ! snow tracer quantities
              do nc = 1, ncat
                 if (vsnon(n,nc) > c0) then
                    do k = 1, nslyr
                       rsnwavg  = rsnwavg  + trcrn(n,nt_rsnw +k-1,nc) ! snow grain radius
                       rhosavg  = rhosavg  + trcrn(n,nt_rhos +k-1,nc) ! compacted snow density
                       smicetot = smicetot + trcrn(n,nt_smice+k-1,nc) * vsnon(n,nc)
                       smliqtot = smliqtot + trcrn(n,nt_smliq+k-1,nc) * vsnon(n,nc)
                    end do
                 endif
                 smtot = smtot + rhos * vsnon(n,nc) ! mass of ice in standard density snow
              end do
              rsnwavg  = rsnwavg  / real(nslyr*ncat,kind=dbl_kind) ! snow grain radius
              rhosavg  = rhosavg  / real(nslyr*ncat,kind=dbl_kind) ! compacted snow density
              smicetot = smicetot / real(nslyr,kind=dbl_kind) ! mass of ice in snow
              smliqtot = smliqtot / real(nslyr,kind=dbl_kind) ! mass of liquid in snow
           end if

        endif
        if (vice(n) /= c0) then 
          psalt = work2(n)/vice(n)
          darcyavg = work3(n) / vice(n)
          spnd = work4(n) / vice(n)
          hocnavg = work5(n) / vice(n)
          perm_harmavg = work6(n) / vice(n)
        endif /= c0) psalt = work2(n)/vice(n)
        pTsfc = trcr(n,nt_Tsfc)   ! ice/snow sfc temperature
        pevap = evap(n)*dt/rhoi   ! sublimation/condensation
        pdhi(n) = vice(n) - pdhi(n)  ! ice thickness change
        pdhs(n) = vsno(n) - pdhs(n)  ! snow thickness change
        pde(n) =-(work1(n)- pde(n))/dt ! ice/snow energy change
        pfhocn = -fhocn(n)        ! ocean heat used by ice
        hpnd = trcr(n, nt_hpnd)
        apnd = trcr(n, nt_apnd)

        ice_mass = hocnavg*rhow - hpnd*apnd*rhow - rhos*vsno(n)
        work3(:) = c0

        do k = 1, n_iso
           work3 (n)  =  (trcr(n,nt_isosno+k-1)*vsno(n) &
                         +trcr(n,nt_isoice+k-1)*vice(n))
           pdiso(n,k) = work3(n) - pdiso(n,k)
        enddo

        !-----------------------------------------------------------------
        ! start spewing
        !-----------------------------------------------------------------

        write(nu_diag_out+n-1,899) nx_names(n)

        write(nu_diag_out+n-1,*) '                         '
        write(nu_diag_out+n-1,*) '----------atm----------'
        write(nu_diag_out+n-1,900) 'air temperature (C)    = ',pTair
        write(nu_diag_out+n-1,900) 'specific humidity      = ',Qa(n)
        write(nu_diag_out+n-1,900) 'snowfall (m)           = ',pfsnow
        write(nu_diag_out+n-1,900) 'rainfall (m)           = ',pfrain
        if (.not.calc_Tsfc) then
          write(nu_diag_out+n-1,900) 'total surface heat flux= ', fsurf(n)
          write(nu_diag_out+n-1,900) 'top sfc conductive flux= ',fcondtop(n)
          write(nu_diag_out+n-1,900) 'bot  conductive flux   = ',fcondbot(n)
          write(nu_diag_out+n-1,900) 'latent heat flux       = ',flat(n)
          write(nu_diag_out+n-1,900) 'bot  conductive flux   = ',fcondbot(n)
        else
          write(nu_diag_out+n-1,900) 'shortwave radiation sum= ',fsw(n)
          write(nu_diag_out+n-1,900) 'longwave radiation     = ',flw(n)
        endif
        write(nu_diag_out+n-1,*) '----------ice----------'
        write(nu_diag_out+n-1,900) 'area fraction          = ',aice(n)! ice area
        write(nu_diag_out+n-1,900) 'avg ice thickness (m)  = ',hiavg
        write(nu_diag_out+n-1,900) 'avg snow depth (m)     = ',hsavg
        write(nu_diag_out+n-1,900) 'avg salinity (ppt)     = ',psalt
        write(nu_diag_out+n-1,900) 'avg brine thickness (m)= ',hbravg
        if (tr_fsd) &
        write(nu_diag_out+n-1,900) 'avg fsd rep radius (m) = ',fsdavg

        if (calc_Tsfc) then
          write(nu_diag_out+n-1,900) 'surface temperature(C) = ',pTsfc ! ice/snow
          write(nu_diag_out+n-1,900) 'absorbed shortwave flx = ',fswabs(n)
          write(nu_diag_out+n-1,900) 'outward longwave flx   = ',flwout(n)
          write(nu_diag_out+n-1,900) 'sensible heat flx      = ',fsens(n)
          write(nu_diag_out+n-1,900) 'latent heat flx        = ',flat(n)
        endif
        write(nu_diag_out+n-1,900) 'subl/cond (m ice)      = ',pevap   ! sublimation/condensation
        write(nu_diag_out+n-1,900) 'top melt (m)           = ',meltt(n)
        write(nu_diag_out+n-1,900) 'bottom melt (m)        = ',meltb(n)
        write(nu_diag_out+n-1,900) 'lateral melt (m)       = ',meltl(n)
        write(nu_diag_out+n-1,900) 'new ice (m)            = ',frazil(n) ! frazil
        write(nu_diag_out+n-1,900) 'congelation (m)        = ',congel(n)
        write(nu_diag_out+n-1,900) 'snow-ice (m)           = ',snoice(n)
        write(nu_diag_out+n-1,900) 'snow change (m)        = ',dsnow(n)
        write(nu_diag_out+n-1,900) 'effective dhi (m)      = ',pdhi(n)   ! ice thickness change
        write(nu_diag_out+n-1,900) 'effective dhs (m)      = ',pdhs(n)   ! snow thickness change
        write(nu_diag_out+n-1,900) 'intnl enrgy chng(W/m^2)= ',pde (n)   ! ice/snow energy change
        write(nu_diag_out+n-1,900) 'pond height (m)        = ',hpnd
        write(nu_diag_out+n-1,900) 'melt mond area fraction= ',apnd
        write(nu_diag_out+n-1,900) 'pond salinity (ppt)    = ',spnd
        write(nu_diag_out+n-1,900) 'darcy speed (+down m/s)= ',darcyavg
        write(nu_diag_out+n-1,900) 'ocean height (m)       = ',hocnavg
        write(nu_diag_out+n-1,900) 'ice mass (kg m-2)      = ',ice_mass
        write(nu_diag_out+n-1,900) 'ice permeability (m2)  = ',perm_harmavg
        write(nu_diag_out+n-1,900) 'pond albedo            = ',albpnd(n)
        write(nu_diag_out+n-1,900) 'pump amount (m)        = ',pump_amnt(n)

        if (tr_snow) then
           if (trim(snwredist) /= 'none') then
              write(nu_diag_out+n-1,900) 'avg snow density(kg/m3)= ',rhosavg
           endif
           if (snwgrain) then
              write(nu_diag_out+n-1,900) 'avg snow grain radius  = ',rsnwavg
              write(nu_diag_out+n-1,900) 'mass ice in snow(kg/m2)= ',smicetot
              write(nu_diag_out+n-1,900) 'mass liq in snow(kg/m2)= ',smliqtot
              write(nu_diag_out+n-1,900) 'mass ice+liq    (kg/m2)= ',smicetot+smliqtot
              write(nu_diag_out+n-1,900) 'mass std snow   (kg/m2)= ',smtot
              write(nu_diag_out+n-1,900) 'max  ice+liq    (kg/m2)= ',rhow * hsavg
           endif
        endif

        write(nu_diag_out+n-1,*) '----------ocn----------'
        write(nu_diag_out+n-1,900) 'sst (C)                = ',sst(n)  ! sea surface temperature
        write(nu_diag_out+n-1,900) 'sss (ppt)              = ',sss(n)  ! sea surface salinity
        write(nu_diag_out+n-1,900) 'freezing temp (C)      = ',Tf(n)   ! freezing temperature
        write(nu_diag_out+n-1,900) 'heat used (W/m^2)      = ',pfhocn  ! ocean heat used by ice

        if (tr_iso) then
          do k = 1, n_iso
             write(nu_diag_out+n-1,901) 'isotopic precip      = ',fiso_atm(n,k)*dt,k
             write(nu_diag_out+n-1,901) 'isotopic evap/cond   = ',fiso_evap(n,k)*dt,k
             write(nu_diag_out+n-1,901) 'isotopic loss to ocn = ',fiso_ocn(n,k)*dt,k
             write(nu_diag_out+n-1,901) 'isotopic gain/loss   = ',(fiso_atm(n,k)-fiso_ocn(n,k)+fiso_evap(n,k))*dt,k
             write(nu_diag_out+n-1,901) 'isotopic conc chg    = ',pdiso(n,k),k
          enddo
        endif
        call icedrv_system_flush(nu_diag_out+n-1)
      end do
899   format (43x,a24)
900   format (a25,2x,f24.17)
901   format (a25,2x,f24.17,i6)

      end subroutine runtime_diags

!=======================================================================

! Computes global combined ice and snow mass sum
!
! author: Elizabeth C. Hunke, LANL

      subroutine init_mass_diags

      use icedrv_state, only: vice, vsno, trcr

      integer (kind=int_kind) :: i, k, nt_isosno, nt_isoice

      real (kind=dbl_kind), dimension (nx) :: work1

      character(len=*), parameter :: subname='(init_mass_diags)'

      call icepack_query_tracer_indices(nt_isosno_out=nt_isosno)
      call icepack_query_tracer_indices(nt_isoice_out=nt_isoice)

      call total_energy (work1)
      do i = 1, nx
         pdhi(i) = vice (i)
         pdhs(i) = vsno (i)
         pde (i) = work1(i)
         do k = 1, n_iso
            pdiso(i,k) = (trcr(i,nt_isosno+k-1)*vsno(i) &
                         +trcr(i,nt_isoice+k-1)*vice(i))
         enddo
      enddo

      end subroutine init_mass_diags

!=======================================================================

! Computes total energy of ice and snow in a grid cell.
!
! authors: E. C. Hunke, LANL

      subroutine total_energy (work)

      use icedrv_state, only: vicen, vsnon, trcrn

      real (kind=dbl_kind), dimension (nx), intent(out) :: &
         work      ! total energy

      ! local variables

      integer (kind=int_kind) :: &
        i, k, n

      integer (kind=int_kind) :: nt_qice, nt_qsno

      character(len=*), parameter :: subname='(total_energy)'

      !-----------------------------------------------------------------
      ! query Icepack values
      !-----------------------------------------------------------------

         call icepack_query_tracer_indices(nt_qice_out=nt_qice, nt_qsno_out=nt_qsno)
         call icepack_warnings_flush(nu_diag)
         if (icepack_warnings_aborted()) call icedrv_system_abort(string=subname, &
             file=__FILE__,line= __LINE__)

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
            do k = 1, nilyr
               do i = 1, nx
                  work(i) = work(i) &
                          + trcrn(i,nt_qice+k-1,n) &
                          * vicen(i,n) / real(nilyr,kind=dbl_kind)
               enddo            ! i
            enddo               ! k

            do k = 1, nslyr
               do i = 1, nx
                  work(i) = work(i) &
                          + trcrn(i,nt_qsno+k-1,n) &
                          * vsnon(i,n) / real(nslyr,kind=dbl_kind)
               enddo            ! i
            enddo               ! k
         enddo                  ! n

      end subroutine total_energy

!=======================================================================

! Computes bulk salinity of ice and snow in a grid cell.
! author: E. C. Hunke, LANL

      subroutine total_salt (work)

      use icedrv_state, only: vicen, trcrn

      real (kind=dbl_kind), dimension (nx),  &
         intent(out) :: &
         work      ! total salt

      ! local variables

      integer (kind=int_kind) :: &
        i, k, n

      integer (kind=int_kind) :: nt_sice

      character(len=*), parameter :: subname='(total_salt)'

      !-----------------------------------------------------------------
      ! query Icepack values
      !-----------------------------------------------------------------

         call icepack_query_tracer_indices(nt_sice_out=nt_sice)
         call icepack_warnings_flush(nu_diag)
         if (icepack_warnings_aborted()) call icedrv_system_abort(string=subname, &
             file=__FILE__,line= __LINE__)

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
            do k = 1, nilyr
               do i = 1, nx
                  work(i) = work(i) &
                          + trcrn(i,nt_sice+k-1,n) &
                          * vicen(i,n) / real(nilyr,kind=dbl_kind)
               enddo            ! i
            enddo               ! k
         enddo                  ! n

      end subroutine total_salt
!=======================================================================

! Computes darcy velocity in a grid cell.

      subroutine total_darcy (work)

      use icedrv_domain_size, only: ncat, nx
      use icedrv_state, only: vicen, darcy

      real (kind=dbl_kind), dimension (nx),  &
         intent(out) :: &
         work      ! total darcy

      ! local variables

      integer (kind=int_kind) :: &
        i, n

      integer (kind=int_kind) :: nt_sice

      character(len=*), parameter :: subname='(total_darcy)'

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
           do i = 1, nx
              work(i) = work(i) &
                      + darcy(i,n) &
                      * vicen(i,n)
           enddo            ! i
         enddo               ! k

      end subroutine total_darcy

!=======================================================================

! Computes total pond salinity in a grid cell.

      subroutine total_spond (work)

      use icedrv_domain_size, only: ncat, nx
      use icedrv_state, only: vicen, Spond

      real (kind=dbl_kind), dimension (nx),  &
         intent(out) :: &
         work      ! total spond

      ! local variables

      integer (kind=int_kind) :: &
        i, n

      integer (kind=int_kind) :: nt_sice

      character(len=*), parameter :: subname='(total_spond)'

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
           do i = 1, nx
              work(i) = work(i) &
                      + Spond(i,n) &
                      * vicen(i,n)
           enddo            ! i
         enddo               ! k

      end subroutine total_spond

!=======================================================================

! Computes total ocean height.

      subroutine total_hocn (work)

      use icedrv_domain_size, only: ncat, nx
      use icedrv_state, only: vicen, hocn

      real (kind=dbl_kind), dimension (nx),  &
         intent(out) :: &
         work      ! total spond

      ! local variables

      integer (kind=int_kind) :: &
        i, n

      integer (kind=int_kind) :: nt_sice

      character(len=*), parameter :: subname='(total_hocn)'

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
           do i = 1, nx
              work(i) = work(i) &
                      + hocn(i,n) &
                      * vicen(i,n)
           enddo            ! i
         enddo               ! k

      end subroutine total_hocn


!=======================================================================

! Computes total ocean height.

      subroutine total_perm_harm (work)

      use icedrv_domain_size, only: ncat, nx
      use icedrv_state, only: vicen, perm_harm

      real (kind=dbl_kind), dimension (nx),  &
         intent(out) :: &
         work      ! total spond

      ! local variables

      integer (kind=int_kind) :: &
        i, n

      character(len=*), parameter :: subname='(total_perm_harm)'

      !-----------------------------------------------------------------
      ! Initialize
      !-----------------------------------------------------------------

         work(:) = c0

      !-----------------------------------------------------------------
      ! Aggregate
      !-----------------------------------------------------------------

         do n = 1, ncat
           do i = 1, nx
              work(i) = work(i) &
                      + perm_harm(i,n) &
                      * vicen(i,n)
           enddo            ! i
         enddo               ! k

      end subroutine total_perm_harm
!=======================================================================
!
! Wrapper for the print_state debugging routine.
! Useful for debugging in the main driver (see ice.F_debug)
!
! author Elizabeth C. Hunke, LANL
!
      subroutine icedrv_diagnostics_debug (plabeld)

      use icedrv_calendar, only: istep1

      character (*), intent(in) :: plabeld

      character(len=*), parameter :: &
         subname='(icedrv_diagnostics_debug)'

      ! printing info for routine print_state

      integer (kind=int_kind), parameter :: &
         check_step = 1, & ! begin printing at istep1=check_step
         ip = 3               ! i index

      if (istep1 >= check_step) then
         call print_state(plabeld,ip)
      endif

      end subroutine icedrv_diagnostics_debug

!=======================================================================

! This routine is useful for debugging.
! Calls to it should be inserted in the form (after thermo, for example)
!     plabel = 'post thermo'
!     if (istep1 >= check_step) call print_state(plabel,ip)
! 'use ice_diagnostics' may need to be inserted also
! author: Elizabeth C. Hunke, LANL

      subroutine print_state(plabel,i)

      use icedrv_calendar,  only: istep1, time
      use icedrv_state, only: aice0, aicen, vicen, vsnon, uvel, vvel, trcrn
      use icedrv_flux, only: uatm, vatm, potT, Tair, Qa, flw, frain, fsnow
      use icedrv_flux, only: fsens, flat, evap, flwout
      use icedrv_flux, only: swvdr, swvdf, swidr, swidf, rhoa
      use icedrv_flux, only: frzmlt, sst, sss, Tf, Tref, Qref, Uref
      use icedrv_flux, only: uocn, vocn
      use icedrv_flux, only: fsw, fswabs, fswint_ai, fswthru, scale_factor
      use icedrv_flux, only: alvdr_ai, alvdf_ai, alidf_ai, alidr_ai

      character (*), intent(in) :: plabel

      integer (kind=int_kind), intent(in) :: &
          i              ! horizontal index

      ! local variables

      real (kind=dbl_kind) :: &
          eidebug, esdebug, &
          qi, qs, Tsnow, &
          puny, Lfresh, cp_ice, &
          rhoi, rhos

      integer (kind=int_kind) :: n, k

      integer (kind=int_kind) :: nt_Tsfc, nt_qice, nt_qsno, nt_fsd
      integer (kind=int_kind) :: nt_smice, nt_smliq

      logical (kind=log_kind) :: tr_fsd, tr_snow

      character(len=*), parameter :: subname='(print_state)'

      !-----------------------------------------------------------------
      ! query Icepack values
      !-----------------------------------------------------------------

      call icepack_query_tracer_flags(tr_fsd_out=tr_fsd, tr_snow_out=tr_snow)
      call icepack_query_tracer_indices(nt_Tsfc_out=nt_Tsfc, nt_qice_out=nt_qice, &
           nt_qsno_out=nt_qsno,nt_fsd_out=nt_fsd, nt_smice_out=nt_smice, &
           nt_smliq_out=nt_smliq)
      call icepack_query_parameters(puny_out=puny, Lfresh_out=Lfresh, cp_ice_out=cp_ice, &
           rhoi_out=rhoi, rhos_out=rhos)
      call icepack_warnings_flush(nu_diag)
      if (icepack_warnings_aborted()) call icedrv_system_abort(string=subname, &
          file=__FILE__,line= __LINE__)

      !-----------------------------------------------------------------
      ! write diagnostics
      !-----------------------------------------------------------------

      write(nu_diag,*) trim(plabel)
      write(nu_diag,*) 'istep1, i, time', &
                        istep1, i, time
      write(nu_diag,*) ' '
      write(nu_diag,*) 'aice0', aice0(i)
      do n = 1, ncat
         write(nu_diag,*) ' '
         write(nu_diag,*) 'n =',n
         write(nu_diag,*) 'aicen', aicen(i,n)
         write(nu_diag,*) 'vicen', vicen(i,n)
         write(nu_diag,*) 'vsnon', vsnon(i,n)
         if (aicen(i,n) > puny) then
            write(nu_diag,*) 'hin', vicen(i,n)/aicen(i,n)
            write(nu_diag,*) 'hsn', vsnon(i,n)/aicen(i,n)
         endif
         write(nu_diag,*) 'Tsfcn',trcrn(i,nt_Tsfc,n)
         if (tr_fsd ) write(nu_diag,*) 'afsdn',trcrn(i,nt_fsd,n)   ! fsd cat 1
         if (tr_snow) write(nu_diag,*) 'smice',trcrn(i,nt_smice:nt_smice+nslyr-1,n)
         if (tr_snow) write(nu_diag,*) 'smliq',trcrn(i,nt_smliq:nt_smliq+nslyr-1,n)
         write(nu_diag,*) ' '
      enddo                     ! n

      eidebug = c0
      do n = 1,ncat
         do k = 1,nilyr
            qi = trcrn(i,nt_qice+k-1,n)
            write(nu_diag,*) 'qice, cat ',n,' layer ',k, qi
            eidebug = eidebug + qi
            if (aicen(i,n) > puny) then
               write(nu_diag,*)  'qi/rhoi', qi/rhoi
            endif
         enddo
         write(nu_diag,*) ' '
      enddo
      write(nu_diag,*) 'qice(i)',eidebug
      write(nu_diag,*) ' '

      esdebug = c0
      do n = 1,ncat
         if (vsnon(i,n) > puny) then
            do k = 1,nslyr
               qs = trcrn(i,nt_qsno+k-1,n)
               write(nu_diag,*) 'qsnow, cat ',n,' layer ',k, qs
               esdebug = esdebug + qs
               Tsnow = (Lfresh + qs/rhos) / cp_ice
               write(nu_diag,*) 'qs/rhos', qs/rhos
               write(nu_diag,*) 'Tsnow', Tsnow
            enddo
            write(nu_diag,*) ' '
         endif
      enddo
      write(nu_diag,*) 'qsnow(i)',esdebug
      write(nu_diag,*) ' '

      write(nu_diag,*) 'uvel(i)',uvel(i)
      write(nu_diag,*) 'vvel(i)',vvel(i)

      write(nu_diag,*) ' '
      write(nu_diag,*) 'atm states and fluxes'
      write(nu_diag,*) '            uatm    = ',uatm (i)
      write(nu_diag,*) '            vatm    = ',vatm (i)
      write(nu_diag,*) '            potT    = ',potT (i)
      write(nu_diag,*) '            Tair    = ',Tair (i)
      write(nu_diag,*) '            Qa      = ',Qa   (i)
      write(nu_diag,*) '            rhoa    = ',rhoa (i)
      write(nu_diag,*) '            swvdr   = ',swvdr(i)
      write(nu_diag,*) '            swvdf   = ',swvdf(i)
      write(nu_diag,*) '            swidr   = ',swidr(i)
      write(nu_diag,*) '            swidf   = ',swidf(i)
      write(nu_diag,*) '            flw     = ',flw  (i)
      write(nu_diag,*) '            frain   = ',frain(i)
      write(nu_diag,*) '            fsnow   = ',fsnow(i)
      write(nu_diag,*) ' '
      write(nu_diag,*) 'ocn states and fluxes'
      write(nu_diag,*) '            frzmlt  = ',frzmlt (i)
      write(nu_diag,*) '            sst     = ',sst    (i)
      write(nu_diag,*) '            sss     = ',sss    (i)
      write(nu_diag,*) '            Tf      = ',Tf     (i)
      write(nu_diag,*) '            uocn    = ',uocn   (i)
      write(nu_diag,*) '            vocn    = ',vocn   (i)
      write(nu_diag,*) ' '
      write(nu_diag,*) 'srf states and fluxes'
      write(nu_diag,*) '            Tref    = ',Tref  (i)
      write(nu_diag,*) '            Qref    = ',Qref  (i)
      write(nu_diag,*) '            Uref    = ',Uref  (i)
      write(nu_diag,*) '            fsens   = ',fsens (i)
      write(nu_diag,*) '            flat    = ',flat  (i)
      write(nu_diag,*) '            evap    = ',evap  (i)
      write(nu_diag,*) '            flwout  = ',flwout(i)
      write(nu_diag,*) ' '
      write(nu_diag,*) 'shortwave'
      write(nu_diag,*) '            fsw          = ',fsw         (i)
      write(nu_diag,*) '            fswabs       = ',fswabs      (i)
      write(nu_diag,*) '            fswint_ai    = ',fswint_ai   (i)
      write(nu_diag,*) '            fswthru      = ',fswthru     (i)
      write(nu_diag,*) '            scale_factor = ',scale_factor(i)
      write(nu_diag,*) '            alvdr        = ',alvdr_ai    (i)
      write(nu_diag,*) '            alvdf        = ',alvdf_ai    (i)
      write(nu_diag,*) '            alidr        = ',alidr_ai    (i)
      write(nu_diag,*) '            alidf        = ',alidf_ai    (i)
      write(nu_diag,*) ' '

      call icepack_warnings_flush(nu_diag)
      call icedrv_system_flush(nu_diag)

      end subroutine print_state

!=======================================================================

      end module icedrv_diagnostics

!=======================================================================
