/* Copyright (c) 1997-2000 Graham Barr <gbarr@pobox.com>. All rights reserved.
 * This program is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */
#define PERL_NO_GET_CONTEXT /* we want efficiency */
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#define NEED_sv_2pv_flags
#define NEED_gv_fetchpvn_flags
#include "ppport.h"

#ifndef sv_copypv
#define sv_copypv(a, b) my_sv_copypv(aTHX_ a, b)
static void
my_sv_copypv(pTHX_ SV *const dsv, SV *const ssv)
{
    STRLEN len;
    const char * const s = SvPV_const(ssv,len);
    sv_setpvn(dsv,s,len);
    if(SvUTF8(ssv))
        SvUTF8_on(dsv);
    else
        SvUTF8_off(dsv);
}
#endif

/* Magic for set_subname */
static MGVTBL subname_vtbl;

MODULE=Sub::Util       PACKAGE=Sub::Util

void
set_prototype(proto, code)
    SV *proto
    SV *code
PREINIT:
    SV *cv; /* not CV * */
PPCODE:
    SvGETMAGIC(code);
    if(!SvROK(code))
        croak("set_prototype: not a reference");

    cv = SvRV(code);
    if(SvTYPE(cv) != SVt_PVCV)
        croak("set_prototype: not a subroutine reference");

    if(SvPOK(proto)) {
        /* set the prototype */
        sv_copypv(cv, proto);
    }
    else {
        /* delete the prototype */
        SvPOK_off(cv);
    }

    PUSHs(code);
    XSRETURN(1);

void
set_subname(name, sub)
    SV *name
    SV *sub
PREINIT:
    CV *cv = NULL;
    GV *gv;
    HV *stash = CopSTASH(PL_curcop);
    const char *s, *end = NULL, *begin = NULL;
    MAGIC *mg;
    STRLEN namelen;
    int utf8flag = SvUTF8(name);
    const char* nameptr = SvPV(name, namelen);
    int seen_quote = 0, need_subst = 0;
PPCODE:
    if (!SvROK(sub) && SvGMAGICAL(sub))
        mg_get(sub);
    if (SvROK(sub))
        cv = (CV *) SvRV(sub);
    else if (SvTYPE(sub) == SVt_PVGV)
        cv = GvCVu(sub);
    else if (!SvOK(sub))
        croak(PL_no_usym, "a subroutine");
    else if (PL_op->op_private & HINT_STRICT_REFS)
        croak("Can't use string (\"%.32s\") as %s ref while \"strict refs\" in use",
              SvPV_nolen(sub), "a subroutine");
    else if ((gv = gv_fetchsv(sub, FALSE, SVt_PVCV)))
        cv = GvCVu(gv);
    if (!cv)
        croak("Undefined subroutine %s", SvPV_nolen(sub));
    if (SvTYPE(cv) != SVt_PVCV && SvTYPE(cv) != SVt_PVFM)
        croak("Not a subroutine reference");
    for (s = nameptr; s <= nameptr + namelen; s++) {
        if (*s == ':' && s[-1] == ':') {
            end = s - 1;
            begin = ++s;
            if (seen_quote)
                need_subst++;
        }
        else if (*s && s[-1] == '\'') {
            end = s - 1;
            begin = s;
            if (seen_quote++)
                need_subst++;
        }
    }
    s--;
    if (end) {
        SV* tmp;
        if (need_subst) {
            STRLEN length = end - nameptr + seen_quote - (*end == '\'' ? 1 : 0);
            char* left;
            int i, j;
            tmp = newSV(length);
            left = SvPVX(tmp);
            for (i = 0, j = 0; j < end - nameptr; ++i, ++j) {
                if (nameptr[j] == '\'') {
                    left[i] = ':';
                    left[++i] = ':';
                }
                else {
                    left[i] = nameptr[j];
                }
            }
            stash = gv_stashpvn(left, length, GV_ADD | utf8flag);
            SvREFCNT_dec(tmp);
        }
        else
            stash = gv_stashpvn(nameptr, end - nameptr, GV_ADD | utf8flag);
        nameptr = begin;
        namelen -= begin - nameptr;
    }

    #ifdef PERL_VERSION < 10
    /* under debugger, provide information about sub location */
    if (PL_DBsub && CvGV(cv)) {
        HV *hv = GvHV(PL_DBsub);

        char *new_pkg = HvNAME(stash);

        char *old_name = GvNAME( CvGV(cv) );
        char *old_pkg = HvNAME( GvSTASH(CvGV(cv)) );

        int old_len = strlen(old_name) + strlen(old_pkg);
        int new_len = namelen + strlen(new_pkg);

        SV **old_data;
        char *full_name;

        Newxz(full_name, (old_len > new_len ? old_len : new_len) + 3, char);

        strcat(full_name, old_pkg);
        strcat(full_name, "::");
        strcat(full_name, old_name);

        old_data = hv_fetch(hv, full_name, strlen(full_name), 0);

        if (old_data) {
            strcpy(full_name, new_pkg);
            strcat(full_name, "::");
            strcat(full_name, nameptr);

            SvREFCNT_inc(*old_data);
            if (!hv_store(hv, full_name, strlen(full_name), *old_data, 0))
                SvREFCNT_dec(*old_data);
        }
        Safefree(full_name);
    }
    #endif

    gv = (GV *) newSV(0);
    gv_init_pvn(gv, stash, nameptr, s - nameptr, GV_ADDMULTI | utf8flag);

    /*
     * set_subname needs to create a GV to store the name. The CvGV field of a
     * CV is not refcounted, so perl wouldn't know to SvREFCNT_dec() this GV if
     * it destroys the containing CV. We use a MAGIC with an empty vtable
     * simply for the side-effect of using MGf_REFCOUNTED to store the
     * actually-counted reference to the GV.
     */
    mg = SvMAGIC(cv);
    while (mg && mg->mg_virtual != &subname_vtbl)
        mg = mg->mg_moremagic;
    if (!mg) {
        Newxz(mg, 1, MAGIC);
        mg->mg_moremagic = SvMAGIC(cv);
        mg->mg_type = PERL_MAGIC_ext;
        mg->mg_virtual = &subname_vtbl;
        SvMAGIC_set(cv, mg);
    }
    if (mg->mg_flags & MGf_REFCOUNTED)
        SvREFCNT_dec(mg->mg_obj);
    mg->mg_flags |= MGf_REFCOUNTED;
    mg->mg_obj = (SV *) gv;
    SvRMAGICAL_on(cv);
    CvANON_off(cv);
#ifndef CvGV_set
    CvGV(cv) = gv;
#else
    CvGV_set(cv, gv);
#endif
    PUSHs(sub);

void
subname(code)
    SV *code
PREINIT:
    CV *cv;
    GV *gv;
    HV *hv;
PPCODE:
    if (!SvROK(code) && SvGMAGICAL(code))
        mg_get(code);

    if(!SvROK(code) || SvTYPE(cv = (CV *)SvRV(code)) != SVt_PVCV)
        croak("Not a subroutine reference");

    if(!(gv = CvGV(cv)))
        XSRETURN(0);

    hv = GvSTASH(gv);

    mPUSHs(newSVpvf("%s::%s", (hv ? HvNAME(hv) : "__ANON__"), GvNAME(gv)));
    XSRETURN(1);
