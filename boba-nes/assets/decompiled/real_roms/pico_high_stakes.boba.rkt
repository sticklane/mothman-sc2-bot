#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : MOT Grand Prix 2 (mot_grandprix2-0.p8)
;; Source ROM : assets/roms/pico/mot_grandprix2-0.p8 (84037 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "high_stakes")
  (title "MOT Grand Prix 2 (mot_grandprix2-0.p8)")
  (rom-source "pico/mot_grandprix2-0.p8")
  (rom-bytes 84037)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label map sfx music))
    (lua-line-count 1270)
    (lifted-function-count 78)
    (gfx-row-count 128)
    (map-row-count 25)
    (gff-row-count 0)
    (sfx-row-count 23)
    (music-row-count 34))
  ;; --- 2. Hardware Interrupt Vectors & Entry Points ---
  (interrupt-vectors
    (init-hook _init)
    (update-hook _update)
    (draw-hook _draw))
  ;; --- 3. Graded Coeffect-Effect Resource & Capability Summary ---
  (coeffect-grades
    (Phi1-frame-budget 32768)
    (Phi2-token-count 8192)
    (Phi2-token-budget 8192)
    (Phi3-sram-bytes 8192)
    (CapMem RamLinear))
  (hardware-capabilities
    (lifted-functions (_draw _init _update anim_draw applyraceresults basepal clamp clr confirm cprint dadd data datahdr dataint dexp dinp dinsp doafterframe drawanim drawconfirm drawfade drawgamename drawleaderboard drawmenu dui fadein findrefkeyframes framedone fromhexchar getmenuitems getmodeanimset getvirtualkeyframe lerp loadanims loadspriteanim loadtlanim loadtournament makeevent makekeyframe makerandomroster makespriteanim makespriteframe maketl maketlanim mem_r1 mem_size mprint mus newtournament pprint quittournament randomnums read2 readmemstream readstr readstrfixed readstrstream reltxt runcoroutines rungame savetournament sfx smap sort sprcoords spriteanim_draw spriteanim_duration str_r1 str_size tilecoords tlanim_draw tlanim_duration transition txt updateconfirm updatefade updateleaderboard updatemenu))
    (pico8-api-calls (add all btn btnp camera ceil clip cls cos del flr line max memset mid min music pal palt peek poke print rect rectfill rnd sfx sin spr sspr))
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 25)
    (active-sfx-lifted 23)
    (active-music-lifted 33))
  ;; --- 4. Symbolic MMIO Cross-Reference, Subroutines & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function
      (name dataint)
      (params (lines props globname))
      (line-range (10 18))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function dataint(lines,props,globname)"
        " local d={}"
        " for l in all(lines) do"
        "  local o,v={},split(l)"
        "  for i,val in ipairs(v) do"
        "   if val~=\"\" then"
        "    if(glob[val]~=nil)val=glob[val]"
        "\t   o[props[i]]=val"
        "\t  end"))
    (def-pico-function
      (name data)
      (params (str globname))
      (line-range (29 33))
      (api-calls ())
      (called-functions (dataint))
      (body-lines
        "function data(str,globname)"
        " local lines=split(str,chr(10))"
        " local props=split(deli(lines,1))"
        " return dataint(lines,props,globname)"
        "end"))
    (def-pico-function
      (name datahdr)
      (params (propstr str globname))
      (line-range (35 37))
      (api-calls ())
      (called-functions (dataint))
      (body-lines
        "function datahdr(propstr,str,globname)"
        " return dataint(split(str,chr(10)),split(propstr),globname)"
        "end"))
    (def-pico-function
      (name sort)
      (params (array compfn))
      (line-range (39 45))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function sort(array,compfn)"
        " for i=2,#array do"
        "  local c,j=array[i],i"
        "  while j>1 and compfn(array[j-1],c) do"
        "   array[j]=array[j-1]"
        "   j-=1"
        "  end"))
    (def-pico-function
      (name runcoroutines)
      (params (co))
      (line-range (60 66))
      (api-calls (all del))
      (called-functions ())
      (body-lines
        "function runcoroutines(co)"
        "\tfor c in all(co) do"
        "\t\tif costatus(c)==\"dead\"then"
        "\t\t\tdel(co,c)"
        "\t\telse"
        "\t\t\tassert(coresume(c))"
        "\t\tend"))
    (def-pico-function
      (name lerp)
      (params (a b f))
      (line-range (70 72))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function lerp(a,b,f)"
        " return (1-f)*a+f*b"
        "end"))
    (def-pico-function
      (name clamp)
      (params (v mn mx))
      (line-range (81 83))
      (api-calls (max min))
      (called-functions ())
      (body-lines
        "function clamp(v,mn,mx)"
        "\treturn min(max(v,mn),mx)"
        "end"))
    (def-pico-function
      (name sprcoords)
      (params (n))
      (line-range (85 87))
      (api-calls (flr))
      (called-functions ())
      (body-lines
        "function sprcoords(n)"
        "\treturn (n%16)*8,flr(n/16)*8"
        "end"))
    (def-pico-function
      (name tilecoords)
      (params (n))
      (line-range (89 91))
      (api-calls (flr))
      (called-functions ())
      (body-lines
        "function tilecoords(n)"
        " return n%128,flr(n/128)"
        "end"))
    (def-pico-function
      (name smap)
      (params (cx cy cw ch sx sy sw sh flipx flipy))
      (line-range (93 101))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function smap(cx,cy,cw,ch,sx,sy,sw,sh,flipx,flipy)"
        " -- delta"
        " local dx,dy=cw/sw,ch/sh"
        " "
        " -- apply flip"
        " if flipx then"
        "  cx+=cw"
        "  dx=-dx"
        " end"))
    (def-pico-function
      (name read2)
      (params (self))
      (line-range (124 126))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function read2(self)"
        " return self:read1()|(self:read1()<<8)"
        "end"))
    (def-pico-function
      (name mem_size)
      (params (self))
      (line-range (130 132))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function mem_size(self)"
        "\treturn self.addr-self.baseaddr"
        "end"))
    (def-pico-function
      (name mem_r1)
      (params (self))
      (line-range (134 138))
      (api-calls (peek))
      (called-functions ())
      (body-lines
        "function mem_r1(self)"
        " local v=peek(self.addr)"
        " self.addr+=1"
        " return v"
        "end"))
    (def-pico-function
      (name readmemstream)
      (params (addr))
      (line-range (140 148))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function readmemstream(addr)"
        "\treturn {"
        "\t\tbaseaddr=addr,"
        "\t\taddr=addr,"
        "\t\tsize=mem_size,"
        "\t\tread1=mem_r1,"
        "\t\tread2=read2"
        "\t}"
        "end"))
    (def-pico-function
      (name fromhexchar)
      (params (c))
      (line-range (152 154))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function fromhexchar(c)"
        " return ord(c)-(c>\"9\" and 87 or 48)"
        "end"))
    (def-pico-function
      (name str_size)
      (params (self))
      (line-range (156 158))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function str_size(self)"
        "\treturn #self.str/2"
        "end"))
    (def-pico-function
      (name str_r1)
      (params (self))
      (line-range (160 168))
      (api-calls (flr))
      (called-functions (fromhexchar))
      (body-lines
        "function str_r1(self)"
        " local str,offs=self.strs[flr(self.offs>>10)+1],self.offs&0x3ff"
        " offs+=1"
        " local hi=fromhexchar(sub(str,offs,offs))"
        " offs+=1"
        " local lo=fromhexchar(sub(str,offs,offs))"
        " self.offs+=2"
        " return (hi<<4)|lo"
        "end "))
    (def-pico-function
      (name readstrstream)
      (params (strs))
      (line-range (170 178))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function readstrstream(strs)"
        "\treturn {"
        "\t\tstrs=strs,"
        "\t\toffs=0,"
        "\t\tsize=str_size,"
        "\t\tread1=str_r1,"
        "\t\tread2=read2"
        "\t}"
        "end"))
    (def-pico-function
      (name readstrfixed)
      (params (stream len))
      (line-range (182 186))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function readstrfixed(stream,len)"
        "\tlocal result=\"\""
        "\tfor i=1,len do"
        "\t\tresult..=chr(stream:read1())"
        "\tend"))
    (def-pico-function
      (name readstr)
      (params (stream))
      (line-range (190 193))
      (api-calls ())
      (called-functions (readstrfixed))
      (body-lines
        "function readstr(stream)"
        "\tlocal len=stream:read1()"
        "\treturn readstrfixed(stream,len)"
        "end"))
    (def-pico-function
      (name loadanims)
      (params (stream))
      (line-range (197 205))
      (api-calls ())
      (called-functions (readstrfixed))
      (body-lines
        "function loadanims(stream)"
        "\tprinth(\"*** loading animations ***\")"
        ""
        "\t-- verify header and version"
        "\tlocal hdr=readstrfixed(stream,3)"
        "\tif hdr~=\"mas\" then"
        "\t\tprinth(\"'mas' header not found\")"
        "\t\tstop()"
        "\tend"))
    (def-pico-function
      (name loadspriteanim)
      (params (stream))
      (line-range (242 264))
      (api-calls (add))
      (called-functions (makespriteanim read2 readstr))
      (body-lines
        "function loadspriteanim(stream)"
        "\tlocal anim=makespriteanim()"
        "\t"
        "\t-- properties"
        "\tanim.name=readstr(stream)"
        "\tanim.fps=stream:read1()/4"
        "\tanim.w=stream:read1()"
        "\tanim.h=stream:read1()"
        "\tanim.ox=stream:read1()/100"
        "\tanim.oy=stream:read1()/100"
        "\tanim.tr=stream:read1()"
        ""
        "\t-- frames"
        "\tanim.frames={}"
        "\tlocal ct=stream:read1()"
        "\tfor i=1,ct do"
        "\t\tlocal frame={}"
        "\t\tframe.frame=stream:read2()"
        "\t\tlocal flags=stream:read1()"
        "\t\tframe.flipx=(flags&1)==1"
        "\t\tframe.flipy=(flags&2)==2"
        "\t\tadd(anim.frames,frame)"
        "\tend"))
    (def-pico-function
      (name loadtlanim)
      (params (stream typ))
      (line-range (269 293))
      (api-calls ())
      (called-functions (makekeyframe maketlanim read2 readstr))
      (body-lines
        "function loadtlanim(stream,typ)"
        " local anim=maketlanim()"
        " if(typ==3)anim.typ=\"storyboard\""
        " "
        "\t-- properties"
        "\tanim.name=readstr(stream)"
        "\tanim.d=stream:read2()/100"
        "\t"
        "\t-- timelines"
        "\tanim.tls={}"
        "\tlocal ct=stream:read1()"
        "\tfor i=1,ct do"
        "\t local keyframes={}"
        "\t local kct=stream:read1()"
        "\t for j=1,kct do"
        "\t "
        "\t  -- time"
        "\t  local t=stream:read2()/100"
        "\t  local k=makekeyframe(t)"
        "\t  "
        "\t  -- content "
        "\t  local flags=stream:read1()"
        "\t  if (flags&1)~=0 then "
        "\t  \tk.anim=stream:read1()\t\t-- will be converted to object reference later"
        "\t\t\tend"))
    (def-pico-function
      (name spriteanim_draw)
      (params (self t x y xscale yscale flipx flipy))
      (line-range (373 403))
      (api-calls (flr palt))
      (called-functions (clamp smap tilecoords))
      (body-lines
        "function spriteanim_draw(self,t,x,y,xscale,yscale,flipx,flipy)"
        ""
        "\t-- find frame"
        "\tlocal f=clamp(flr(t*self.fps)+1,1,#self.frames)"
        "\tlocal frame=self.frames[f]"
        ""
        "\t-- display width and height"
        "\tlocal dw,dh=self.w*8*xscale,self.h*8*yscale"
        "\t"
        "\t-- flip flags"
        "\tif(frame.flipx)flipx=not flipx"
        "\tif(frame.flipy)flipy=not flipy"
        ""
        "\t-- adjust for orgin pt"
        "\tx-=dw*(flipx and (1-self.ox) or self.ox)"
        "\ty-=dh*(flipy and (1-self.oy) or self.oy)"
        ""
        "\t-- draw"
        "\t-- as tilemap coords"
        "\tpalt(0,false)"
        "\tpalt(self.tr,true)"
        "\tlocal cx,cy=tilecoords(frame.frame)"
        "\tsmap("
        "\t cx,cy,"
        "\t self.w,self.h,"
        "\t x,y,"
        "\t dw,dh,"
        "\t flipx,flipy)"
        " palt(self.tr,false)\t"
        "\tpalt(0,true)"
        "end"))
    (def-pico-function
      (name spriteanim_duration)
      (params (self))
      (line-range (405 407))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function spriteanim_duration(self)"
        "\treturn #self.frames/self.fps"
        "end"))
    (def-pico-function
      (name makespriteanim)
      (params ())
      (line-range (409 424))
      (api-calls ())
      (called-functions (makespriteframe))
      (body-lines
        "function makespriteanim()"
        "\treturn {"
        "\t\ttyp=\"sprite\","
        "\t\tname=\"sprite\","
        "\t\tfps=10,"
        "\t\tw=1,h=1,"
        "\t\tox=0.5,oy=0.5,"
        "\t\ttr=16,"
        "\t\tframes={"
        "\t\t\tmakespriteframe(1),"
        "\t\t},"
        "\t\tduration=spriteanim_duration,"
        "\t\tdodraw=spriteanim_draw,"
        "\t\tdraw=drawanim"
        "\t}"
        "end"))
    (def-pico-function
      (name makespriteframe)
      (params (n))
      (line-range (426 432))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function makespriteframe(n)"
        "\treturn {"
        "\t\tframe=n--,"
        "--\t\tflipx=false,"
        "--\t\tflipy=false"
        "\t}"
        "end"))
    (def-pico-function
      (name tlanim_duration)
      (params (self))
      (line-range (436 438))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function tlanim_duration(self)"
        "\treturn self.d"
        "end"))
    (def-pico-function
      (name findrefkeyframes)
      (params (tl prop t))
      (line-range (444 453))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function findrefkeyframes(tl,prop,t)"
        " -- find nearest frames before/after t"
        " -- where property is not null"
        " local before,after"
        " local beforet,aftert=-1000,1000"
        " for k in all(tl.keyframes) do"
        "  if k[prop] then"
        "   if k.t<=t and k.t>beforet then"
        "    before,beforet=k,k.t"
        "   end"))
    (def-pico-function
      (name getvirtualkeyframe)
      (params (tl t))
      (line-range (462 485))
      (api-calls (all))
      (called-functions (findrefkeyframes))
      (body-lines
        "function getvirtualkeyframe(tl,t)"
        ""
        " -- calculate the effective "
        " -- \"virtual\" keyframe at time t"
        " -- on the timeline, interpolating"
        " -- as necessary."
        " local props={"
        "  visible=true,"
        "  animt=0,animspd=1,"
        "  x=0,y=0,"
        "  xscale=1,yscale=1,"
        "  flipx=false,flipy=false,"
        "  easein=false,easeout=false"
        " }"
        ""
        "\t-- switchover properties"
        " local animtt\t\t\t\t"
        "\tfor prop in all(keyframeswitch) do"
        "\t before,after=findrefkeyframes(tl,prop,t)"
        "\t local frame=before or after"
        "\t if(frame)props[prop]=frame[prop]"
        "\t\tif prop==\"animt\" then"
        "\t\t animtt=before and before.t"
        "\t\tend"))
    (def-pico-function
      (name tlanim_draw)
      (params (self t x y xscale yscale flipx flipy dt r))
      (line-range (527 553))
      (api-calls (all))
      (called-functions (anim_draw getvirtualkeyframe))
      (body-lines
        "function tlanim_draw(self,t,x,y,xscale,yscale,flipx,flipy,dt,r)"
        " -- recursion limit"
        " r+=1"
        " if(r>10) return"
        " "
        " -- draw anims for each timeline"
        " for tl in all(self.tls) do"
        ""
        "  -- get effective keyframe for t"
        "\t\tlocal props=getvirtualkeyframe(tl,t)"
        "\t\t"
        "\t\t-- draw child animation"
        "\t\tif props.visible and props.anim then"
        "\t\t"
        "\t\t -- calculate effective position,scale and flip"
        "\t\t local cx=x+props.x*xscale*(flipx and -1 or 1)"
        "\t\t local cy=y+props.y*yscale*(flipy and -1 or 1)"
        "\t\t local cxscale,cyscale=xscale*props.xscale,yscale*props.yscale"
        "\t\t local cflipx,cflipy=flipx,flipy"
        "   if(props.flipx)cflipx=not cflipx"
        "   if(props.flipy)cflipy=not cflipy"
        "   local cdt=dt and dt*props.animspd"
        "\t\t "
        "\t\t -- draw"
        "\t\t if not anim_draw or anim_draw(props,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r) then"
        "\t\t\t props.anim:dodraw(props.animt,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r)"
        "\t\t\tend"))
    (def-pico-function
      (name makekeyframe)
      (params (t))
      (line-range (567 586))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function makekeyframe(t)"
        "\treturn {"
        "\t\tt=t,"
        "\t\tanim=nil,"
        "\t\tloop=true,"
        "\t\tafter=false,"
        "--\t\tanimt=nil,"
        "--\t\tanimspd=nil,"
        "--\t\tx=nil,"
        "--\t\ty=nil,"
        "--\t\txscale=nil,"
        "--\t\tyscale=nil,"
        "\t\tvisible=true,"
        "\t\tflipx=false,"
        "\t\tflipy=false,"
        "\t\teasein=false,"
        "\t\teaseout=false,"
        "\t\ttag=0"
        "\t}"
        "end"))
    (def-pico-function
      (name makeevent)
      (params (t typ))
      (line-range (588 597))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function makeevent(t,typ)"
        " return {"
        "  t=t,"
        "  typ=\"\"--,"
        "--  x=nil,"
        "--  y=nil,"
        "--  n=nil,"
        "--  txt=nil"
        " }"
        "end"))
    (def-pico-function
      (name maketl)
      (params ())
      (line-range (599 608))
      (api-calls ())
      (called-functions (makekeyframe))
      (body-lines
        "function maketl()"
        ""
        " -- default keyframe"
        " local k=makekeyframe(0)"
        " k.animt,k.animspd,k.x,k.y=0,1,0,0"
        " "
        "\treturn {"
        "\t\tkeyframes={k}\t"
        "\t}"
        "end"))
    (def-pico-function
      (name maketlanim)
      (params ())
      (line-range (610 621))
      (api-calls ())
      (called-functions (maketl))
      (body-lines
        "function maketlanim()"
        "\treturn {"
        "\t\ttyp=\"tl\","
        "\t\tname=\"timeline\","
        "\t\td=10,"
        "\t\ttls={ maketl() },"
        "\t\tevents={ keyframes={} },"
        "\t\tduration=tlanim_duration,"
        "\t\tdodraw=tlanim_draw,"
        "\t\tdraw=drawanim"
        "\t}"
        "end"))
    (def-pico-function
      (name doafterframe)
      (params (fn))
      (line-range (627 629))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "\tlocal function doafterframe(fn)"
        "\t\t add(afterframeco,cocreate(fn))"
        " end"))
    (def-pico-function
      (name sfx)
      (params (ev))
      (line-range (632 632))
      (api-calls (sfx))
      (called-functions ())
      (body-lines
        "  sfx=function(ev)\tsfx(ev.n)         end,"))
    (def-pico-function
      (name mus)
      (params (ev))
      (line-range (633 633))
      (api-calls (music))
      (called-functions ())
      (body-lines
        "  mus=function(ev) music(ev.n or -1) end,"))
    (def-pico-function
      (name txt)
      (params (ev))
      (line-range (634 639))
      (api-calls (print))
      (called-functions (doafterframe))
      (body-lines
        "  txt=function(ev)"
        "   doafterframe(function()"
        "    for i=1,ev.n or 30 do"
        "     print(ev.txt,ev.x,ev.y)"
        "     yield()"
        "    end"))
    (def-pico-function
      (name reltxt)
      (params (ev x y))
      (line-range (642 647))
      (api-calls (print))
      (called-functions (doafterframe))
      (body-lines
        "  reltxt=function(ev,x,y)"
        "   doafterframe(function()"
        "    for i=1,ev.n or 30 do"
        "     print(ev.txt,x+(ev.x or 0),y+(ev.y or 0))"
        "     yield()"
        "    end"))
    (def-pico-function
      (name clr)
      (params ())
      (line-range (650 652))
      (api-calls ())
      (called-functions ())
      (body-lines
        "\t\tclr=function()"
        "\t\t afterframeco={}"
        "\t\tend,"))
    (def-pico-function
      (name framedone)
      (params ())
      (line-range (659 661))
      (api-calls ())
      (called-functions (runcoroutines))
      (body-lines
        "\t\tframedone=function()"
        "\t\t runcoroutines(afterframeco)"
        "\t\tend"))
    (def-pico-function
      (name _init)
      (params ())
      (line-range (724 742))
      (api-calls ())
      (called-functions (loadanims readstrstream))
      (body-lines
        "function _init()"
        " cartdata(\"mot_gpp\")"
        " "
        " -- load animations"
        " local stream=readstrstream(animdata)"
        " anims=loadanims(stream)"
        " anim_events.fin=fadein"
        ""
        " -- load cart data"
        " "
        " -- game state"
        " if dget(10)==0 then"
        "\t\tracetype,dif,lapoption,tracknum=1,2,2,1"
        "\telse\t\t"
        "\t racetype\t=dget(10)"
        " \tdif\t\t\t\t\t\t=dget(11)"
        "\t tracknum\t=dget(12)"
        " \tlapoption=dget(13)"
        " end"))
    (def-pico-function
      (name _draw)
      (params ())
      (line-range (767 773))
      (api-calls (cls))
      (called-functions (basepal drawconfirm drawfade))
      (body-lines
        "function _draw()"
        " cls()"
        " basepal()"
        " if(anim and animt)anim:draw(animt)"
        " if(confirmprompt)drawconfirm()"
        " drawfade()"
        "end"))
    (def-pico-function
      (name _update)
      (params ())
      (line-range (775 784))
      (api-calls ())
      (called-functions (updateconfirm updatemenu))
      (body-lines
        "function _update()"
        " frame+=1"
        " "
        " -- can't update while transitioning"
        " if not istransition then"
        "  if confirmprompt then"
        "   updateconfirm()"
        "  elseif mode==\"title\" then"
        "\t \tupdatemenu()"
        "\t end"))
    (def-pico-function
      (name rungame)
      (params (demo))
      (line-range (804 812))
      (api-calls ())
      (called-functions (makerandomroster))
      (body-lines
        "function rungame(demo)"
        ""
        " if racetype==type_race then"
        " \troster=makerandomroster()"
        " elseif racetype==type_tour then"
        "  roster=tour.roster"
        " else"
        "  roster=nil"
        " end"))
    (def-pico-function
      (name anim_draw)
      (params (props cx cy cxscale cyscale cflipx cflipy cdt r))
      (line-range (851 857))
      (api-calls (pal))
      (called-functions (basepal))
      (body-lines
        "function anim_draw(props,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r)"
        " local tag=props.tag"
        " if tag==1 then "
        " \tpal(pals[2])"
        " else"
        "  basepal()"
        " end"))
    (def-pico-function
      (name drawconfirm)
      (params ())
      (line-range (880 887))
      (api-calls (rect rectfill))
      (called-functions (cprint pprint))
      (body-lines
        "function drawconfirm()"
        " rectfill(0,50,128,77,3)"
        " rect(-1,50,128,77,7)"
        " cprint(confirmprompt,56,6)"
        " local selcol=frame%8<4 and 7 or 6"
        " pprint(\"yES\",50,67,confirmx==0 and selcol or 5)"
        " pprint(\"nO\", 69,67,confirmx==1 and selcol or 5)"
        "end"))
    (def-pico-function
      (name updateconfirm)
      (params ())
      (line-range (889 896))
      (api-calls (btnp))
      (called-functions ())
      (body-lines
        "function updateconfirm()"
        " if(btnp(⬅️))confirmx=0"
        " if(btnp(➡️))confirmx=1"
        " if btnp(❎)or btnp(🅾️) then"
        "  confirmprompt=nil"
        "  if confirmx==0 then"
        "   confirmfn()"
        "  end"))
    (def-pico-function
      (name fadein)
      (params ())
      (line-range (903 908))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function fadein()"
        " fadepixels={}"
        " for i=0,63 do"
        "  sset(i%8,i\\8,0)"
        "  add(fadepixels,i)"
        " end"))
    (def-pico-function
      (name drawfade)
      (params ())
      (line-range (912 917))
      (api-calls (palt spr))
      (called-functions ())
      (body-lines
        "function drawfade()"
        " if fade==\"in\" then"
        "  palt(0,false) palt(1,true)"
        "  for i=0,255 do"
        "   spr(0,i%16*8,i\\16*8)"
        "  end"))
    (def-pico-function
      (name updatefade)
      (params ())
      (line-range (922 928))
      (api-calls (del rnd))
      (called-functions ())
      (body-lines
        "function updatefade()"
        " if fade==\"in\" then"
        "  for k=1,2 do"
        "   local j=rnd(fadepixels)"
        "   del(fadepixels,j)"
        "  \tsset(j%8,j\\8,1)"
        "\t end"))
    (def-pico-function
      (name pprint)
      (params (txt x y c))
      (line-range (932 936))
      (api-calls (print))
      (called-functions ())
      (body-lines
        "function pprint(txt,x,y,c)"
        " for ox=-1,1 do"
        "  for oy=-1,1 do"
        "   print(txt,x+ox,y+oy,1)"
        "  end"))
    (def-pico-function
      (name cprint)
      (params (txt y c))
      (line-range (941 943))
      (api-calls ())
      (called-functions (pprint))
      (body-lines
        "function cprint(txt,y,c)"
        " pprint(txt,65-#txt*2,y,c)"
        "end"))
    (def-pico-function
      (name mprint)
      (params (txt y i))
      (line-range (945 947))
      (api-calls ())
      (called-functions (cprint))
      (body-lines
        "function mprint(txt,y,i)"
        " cprint(txt,y,menui==i and frame%8<4 and not istransition and not confirmprompt and 7 or 6)"
        "end"))
    (def-pico-function
      (name basepal)
      (params ())
      (line-range (949 953))
      (api-calls (pal poke))
      (called-functions ())
      (body-lines
        "function basepal()"
        " pal()"
        " pal(pals[1],1)"
        "\tpoke(0x5f2e,1)"
        "end"))
    (def-pico-function
      (name transition)
      (params (_anim _doneanim _donefn))
      (line-range (955 958))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function transition(_anim,_doneanim,_donefn)"
        " anim,doneanim,donefn=_anim,_doneanim,_donefn"
        " animt,istransition=0,true"
        "end "))
    (def-pico-function
      (name getmodeanimset)
      (params (racetype))
      (line-range (960 968))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function getmodeanimset(racetype)"
        " local modename=racetypeanims[racetype]"
        " return {"
        "  pre=anims[modename..\"pre\"],"
        "  _in=anims[modename..\"in\"],"
        "  idle=anims[modename..\"idle\"],"
        "  out=anims[modename..\"out\"]"
        " } "
        "end"))
    (def-pico-function
      (name makerandomroster)
      (params (t n))
      (line-range (970 972))
      (api-calls ())
      (called-functions (randomnums))
      (body-lines
        "function makerandomroster(t,n)"
        " return randomnums(14,7)"
        "end"))
    (def-pico-function
      (name randomnums)
      (params (t n))
      (line-range (974 978))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function randomnums(t,n)"
        " local allnums={}"
        " for i=1,t do"
        "  add(allnums,i)"
        " end"))
    (def-pico-function
      (name sort)
      (params (array compfn))
      (line-range (986 992))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function sort(array,compfn)"
        " for i=2,#array do"
        "  local c,j=array[i],i"
        "  while j>1 and compfn(array[j-1],c) do"
        "   array[j]=array[j-1]"
        "   j-=1"
        "  end"))
    (def-pico-function
      (name confirm)
      (params (prompt fn))
      (line-range (997 1001))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function confirm(prompt,fn)"
        " confirmprompt=prompt"
        " confirmfn=fn"
        " confirmx=1"
        "end"))
    (def-pico-function
      (name drawgamename)
      (params ())
      (line-range (1006 1010))
      (api-calls (print rectfill))
      (called-functions ())
      (body-lines
        "function drawgamename()"
        " rectfill(20,6,105,37,0)"
        " print(\"\\^pmOT'S\",44,10,7)"
        " print(\"\\^pgRAND pRIX\",24,25,7)"
        "end"))
    (def-pico-function
      (name getmenuitems)
      (params ())
      (line-range (1014 1019))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function getmenuitems()"
        " local items={menu_type}"
        " if racetype~=type_prac then"
        "  add(items,menu_dif)"
        "  add(items,menu_laps)"
        " end"))
    (def-pico-function
      (name drawmenu)
      (params ())
      (line-range (1036 1042))
      (api-calls (palt sspr))
      (called-functions (getmenuitems))
      (body-lines
        "function drawmenu()"
        " local items=getmenuitems()"
        " local yoffs=(5-#items)*3"
        " palt(12,false)"
        " if not istransition and not confirmprompt then"
        "\t sspr(8,0,8,8,0,menuy*8-2+yoffs,128,9)"
        "\tend"))
    (def-pico-function
      (name updatemenu)
      (params ())
      (line-range (1062 1085))
      (api-calls (btnp mid))
      (called-functions (getmenuitems getmodeanimset transition))
      (body-lines
        "function updatemenu()"
        " -- up/down arrows"
        " if(btnp(⬆️))menui-=1"
        " if(btnp(⬇️))menui+=1"
        ""
        " -- find current menu item"
        " local items=getmenuitems()"
        " menui=mid(0,#items-1,menui)"
        " local item=items[menui+1]"
        ""
        " -- left/right arrows"
        " local d=0"
        " if(btnp(⬅️))d-=1"
        " if(btnp(➡️))d+=1"
        ""
        " if item==menu_type and d~=0 then  "
        "  if racetype+d>=1 and racetype+d<=#racetypenames then"
        "\t\t\tlocal prevtype=racetype"
        "\t\t\tracetype+=d"
        "\t\t\tlocal animset,prevset=getmodeanimset(racetype),getmodeanimset(prevtype)"
        "\t\t\tanimsets={animset,prevset}"
        "\t\t\tlocal anim=d<0 and anims[\"tranleft\"] or anims[\"tranright\"]"
        "\t\t\ttransition(anim,anims[\"idle\"])"
        "  end"))
    (def-pico-function
      (name dadd)
      (params (n v i p))
      (line-range (1122 1122))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "lines,s={},0 function dadd(n,v,i,p)while p>1 and lines[p-1].i==i and type(lines[p-1].n)==type(n)and lines[p-1].n>n do p-=1 end add(lines,{n=n,v=v,x=type(v)==\"table\"and\"+\"or\" \",i=i},p)end"))
    (def-pico-function
      (name dexp)
      (params (l p))
      (line-range (1123 1123))
      (api-calls ())
      (called-functions (dadd))
      (body-lines
        "function dexp(l,p)if l.x==\"+\"then for n,v in pairs(l.v)do p+=1 dadd(n,v,l.i..\" \",p)end l.x=\"-\"elseif l.x==\"-\"then while p<#lines and #lines[p+1].i>#lines[p].i do deli(lines,p+1)end\tl.x=\"+\" end end"))
    (def-pico-function
      (name dinp)
      (params ())
      (line-range (1124 1124))
      (api-calls (btnp line max min))
      (called-functions (dexp))
      (body-lines
        "function dinp()local x,y,b,w=stat(32),stat(33),stat(34),stat(36)line(x,y,x,y+2,10)if btnp(❎) then local i=(y-10)\\6+1 local p=s+i local l=lines[p]if l and(x-10)\\4==#l.i then dexp(l,p)end end s=max(min(s-stat(36),#lines-18),0) end"))
    (def-pico-function
      (name dui)
      (params ())
      (line-range (1125 1125))
      (api-calls (print rectfill))
      (called-functions (dinp))
      (body-lines
        "function dui()while true do rectfill(10,10,118,118,1)for i=1,18 do local l=lines[i+s]if l then print(sub(\"\\fc\"..l.i..l.x..l.n..\":\\f7\"..tostr(l.v),1,31),10,(i-1)*6+10,7)end end dinp()flip()end end"))
    (def-pico-function
      (name dinsp)
      (params (v))
      (line-range (1126 1126))
      (api-calls (clip pal poke))
      (called-functions (dadd dui))
      (body-lines
        "function dinsp(v)dadd(\"value\",v,\"\",#lines+1)poke(0x5f2d,3)cursor()pal()clip()dui()end"))
    (def-pico-function
      (name newtournament)
      (params ())
      (line-range (1131 1139))
      (api-calls (add))
      (called-functions (makerandomroster randomnums))
      (body-lines
        "function newtournament()"
        " tour.tracks=randomnums(#tracknames)"
        " tour.tracknum=1"
        " tour.roster=makerandomroster()"
        " tour.playerpts=0"
        " tour.pts={}"
        " for i=1,7 do"
        "  add(tour.pts,0)"
        " end"))
    (def-pico-function
      (name quittournament)
      (params ())
      (line-range (1147 1152))
      (api-calls ())
      (called-functions (savetournament))
      (body-lines
        "function quittournament()"
        ""
        " -- todo: confirmation prompt if tournament running"
        " tour.tracknum=0"
        " savetournament()"
        "end"))
    (def-pico-function
      (name loadtournament)
      (params ())
      (line-range (1154 1165))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function loadtournament()"
        " tour={"
        "  tracknum=dget(40),"
        "  tracks={},"
        "  roster={},"
        "  pts={},"
        "  playerpts=0"
        " }"
        " if tour.tracknum>0 then"
        "  for i=1,#tracknames do"
        "   add(tour.tracks,dget(40+i))"
        "  end"))
    (def-pico-function
      (name savetournament)
      (params ())
      (line-range (1175 1180))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function savetournament()"
        " dset(40,tour.tracknum)"
        " if tour.tracknum>0 then"
        "  for i=1,#tracknames do"
        "   dset(40+i,tour.tracks[i])"
        "  end"))
    (def-pico-function
      (name updateleaderboard)
      (params ())
      (line-range (1189 1198))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function updateleaderboard()"
        " leaderboard={}"
        " for i,car in ipairs(tour.roster) do  "
        "  add(leaderboard,"
        "  \t{"
        "  \t name=aicarnames[car],"
        "  \t p=aicarpals[car],"
        "  \t pts=tour.pts[i]"
        "  \t})"
        " end"))
    (def-pico-function
      (name drawleaderboard)
      (params ())
      (line-range (1207 1222))
      (api-calls (pal palt print spr))
      (called-functions ())
      (body-lines
        "function drawleaderboard()"
        " print(\"driver\",0,1,5)"
        " print(\"points\",58,1,5)"
        " if(tour.tracknum==0)return"
        " for i,e in ipairs(leaderboard) do"
        "  local y,col=i*6+2,e.isplayer and 7 or 6"
        "  pal()"
        "  palt(0,false)"
        "  palt(12,true)"
        "  if(e.p)pal(e.p,0)"
        "  spr(8,0,y)"
        "  pal()"
        "\t\tprint(e.name,10,y,col)"
        "\t\tlocal txt=tostr(e.pts)\t\t"
        "\t\tprint(txt,82-#txt*4,y,col)"
        " end"))
    (def-pico-function
      (name applyraceresults)
      (params ())
      (line-range (1235 1245))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function applyraceresults()"
        ""
        " -- player points"
        " local playerpos=dget(31)"
        " tour.playerpts+=racepts[playerpos]"
        ""
        " -- ai car points"
        " for i=1,7 do"
        "  local pos=dget(31+i)"
        "  tour.pts[i]+=racepts[pos]"
        " end")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id 0 #:grid (0 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00700700" "00077000" "00077000" "00700700" "00000000" "00000000"))
      (def-pico-sprite #:id 1 #:grid (1 0) #:nonzero-pixels 64 #:rows ("cccccccc" "77777777" "77777777" "77777777" "77777777" "77777777" "77777777" "cccccccc"))
      (def-pico-sprite #:id 2 #:grid (2 0) #:nonzero-pixels 26 #:rows ("00000000" "00000007" "00076777" "07777766" "66667777" "00077667" "00000000" "00000000"))
      (def-pico-sprite #:id 3 #:grid (3 0) #:nonzero-pixels 48 #:rows ("00007777" "77777767" "66777777" "77777777" "77777667" "66676667" "76700070" "00000000"))
      (def-pico-sprite #:id 4 #:grid (4 0) #:nonzero-pixels 27 #:rows ("00000000" "00770000" "77770700" "66777777" "66666677" "66770000" "00000000" "00000000"))
      (def-pico-sprite #:id 5 #:grid (5 0) #:nonzero-pixels 19 #:rows ("00000000" "00000000" "00770000" "77777770" "06677667" "00766000" "00000000" "00000000"))
      (def-pico-sprite #:id 6 #:grid (6 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00000000" "00000000" "00000000" "00000000" "00000000" "66886688"))
      (def-pico-sprite #:id 7 #:grid (7 0) #:nonzero-pixels 15 #:rows ("00000000" "00000000" "00000000" "00000000" "00000000" "00000000" "06688668" "66886688"))
      (def-pico-sprite #:id 8 #:grid (8 0) #:nonzero-pixels 64 #:rows ("99cccccc" "c67ccccc" "5577755c" "55999559" "cccccccc" "cccccccc" "cccccccc" "cccccccc"))
      (def-pico-sprite #:id 9 #:grid (9 0) #:nonzero-pixels 64 #:rows ("81111111" "81111111" "81111111" "8ccccccc" "81111111" "81111111" "8ccccccc" "8ccccccc"))
      (def-pico-sprite #:id 10 #:grid (10 0) #:nonzero-pixels 56 #:rows ("11111188" "11111811" "11118100" "cccc8100" "11181100" "11181100" "cc811111" "cc811111"))
      (def-pico-sprite #:id 11 #:grid (11 0) #:nonzero-pixels 56 #:rows ("88111111" "11811111" "00181111" "0018cccc" "00118111" "00118111" "111118cc" "111118cc"))
      (def-pico-sprite #:id 12 #:grid (12 0) #:nonzero-pixels 64 #:rows ("11111118" "11111118" "11111118" "ccccccc8" "11111118" "11111118" "ccccccc8" "ccccccc8"))
      (def-pico-sprite #:id 13 #:grid (13 0) #:nonzero-pixels 64 #:rows ("ccccc677" "ccc11d77" "ccc11d76" "ccc11d51" "cc1dd111" "cc776111" "cc76d111" "cc5115d6"))
      (def-pico-sprite #:id 14 #:grid (14 0) #:nonzero-pixels 64 #:rows ("d1dcc777" "d1117777" "11117776" "11116d51" "d5111111" "6776111d" "6777111d" "115d15d6"))
      (def-pico-sprite #:id 15 #:grid (15 0) #:nonzero-pixels 64 #:rows ("d1dcc677" "d111d677" "1111d676" "11116656" "d51d1117" "67711117" "6771111c" "115155dc"))
      (def-pico-sprite #:id 16 #:grid (0 1) #:nonzero-pixels 64 #:rows ("dddddddd" "dddddddd" "dddddddd" "dddddddd" "dddddddd" "dddddddd" "dddddddd" "dddddddd"))
      (def-pico-sprite #:id 17 #:grid (1 1) #:nonzero-pixels 64 #:rows ("ebebbbee" "ebbbebbe" "beee2eee" "bbbee2ee" "beeeb2e2" "bee2eee2" "ebeee222" "ee22ee2e"))
      (def-pico-sprite #:id 18 #:grid (2 1) #:nonzero-pixels 27 #:rows ("0000b000" "0000b000" "000be200" "00eb2000" "000bee00" "0e0eb220" "0bbee000" "bbee2e20"))
      (def-pico-sprite #:id 19 #:grid (3 1) #:nonzero-pixels 16 #:rows ("0000000b" "0000000b" "000000ee" "0000000e" "00000ebb" "000000eb" "0000b0be" "00000eee"))
      (def-pico-sprite #:id 20 #:grid (4 1) #:nonzero-pixels 15 #:rows ("20000000" "e0000000" "e2000000" "e0000000" "20200000" "e0e00000" "ee220000" "e2000000"))
      (def-pico-sprite #:id 21 #:grid (5 1) #:nonzero-pixels 6 #:rows ("00000000" "00000000" "00000000" "07777000" "00660000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 22 #:grid (6 1) #:nonzero-pixels 20 #:rows ("07777770" "05577550" "00077000" "00077000" "00077000" "00055000" "00000000" "00000000"))
      (def-pico-sprite #:id 23 #:grid (7 1) #:nonzero-pixels 64 #:rows ("cccccccc" "cccccccc" "cccccccc" "cccccccc" "cccccccc" "ccc22222" "cc222222" "cc222222"))
      (def-pico-sprite #:id 24 #:grid (8 1) #:nonzero-pixels 64 #:rows ("cccccccc" "cccccccc" "cccccccc" "cccccccc" "cccccccc" "22222ccc" "222222cc" "222222cc"))
      (def-pico-sprite #:id 25 #:grid (9 1) #:nonzero-pixels 64 #:rows ("8ccccccc" "8ccccccc" "8ccccccc" "8ccccccc" "8ccccccc" "8cc888cc" "8ccaaacc" "8cccccac"))
      (def-pico-sprite #:id 26 #:grid (10 1) #:nonzero-pixels 64 #:rows ("cc8111bb" "cc811eb7" "c811ebbb" "c8119111" "c8117777" "81677666" "8ddd6677" "1dd88888"))
      (def-pico-sprite #:id 27 #:grid (11 1) #:nonzero-pixels 64 #:rows ("bb1118cc" "7be118cc" "bbbe118c" "1119118c" "7777118c" "66677618" "7766ddd8" "88888dd1"))
      (def-pico-sprite #:id 28 #:grid (12 1) #:nonzero-pixels 64 #:rows ("ccccccc8" "ccccccc8" "ccccccc8" "ccccccc8" "ccccccc8" "cc888cc8" "ccaaacc8" "caccccc8"))
      (def-pico-sprite #:id 29 #:grid (13 1) #:nonzero-pixels 64 #:rows ("cc111777" "cd111777" "cd11d776" "c6dd1151" "c7761111" "67771111" "77cccc11" "cccccccc"))
      (def-pico-sprite #:id 30 #:grid (14 1) #:nonzero-pixels 64 #:rows ("11117777" "11117777" "11117776" "6d516d51" "77761111" "7777111d" "777d111d" "cc6d11cc"))
      (def-pico-sprite #:id 31 #:grid (15 1) #:nonzero-pixels 64 #:rows ("1111d77c" "1d11d77c" "1d11d77c" "665ddd5c" "777611cc" "777d11cc" "776d11cc" "cc6111cc")))
    (gff-flags)
    (map-rows
      (def-pico-map-row #:y 0 #:nonzero-tiles 64 #:sample-hex "0000303030090a0b0c30303000000000")
      (def-pico-map-row #:y 1 #:nonzero-tiles 65 #:sample-hex "0000301718191a1b1c17183005000000")
      (def-pico-map-row #:y 2 #:nonzero-tiles 62 #:sample-hex "0000262728292a2b2c2d2e2f00000015")
      (def-pico-map-row #:y 3 #:nonzero-tiles 70 #:sample-hex "0000363738393a3b3c3d3e3f00000000")
      (def-pico-map-row #:y 4 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000024000000")
      (def-pico-map-row #:y 5 #:nonzero-tiles 64 #:sample-hex "00001616161616161616161611240013")
      (def-pico-map-row #:y 6 #:nonzero-tiles 58 #:sample-hex "00000000000000000000000021222423")
      (def-pico-map-row #:y 7 #:nonzero-tiles 70 #:sample-hex "00001616161616161616161631321131")
      (def-pico-map-row #:y 8 #:nonzero-tiles 50 #:sample-hex "00000000000000000000000025353500")
      (def-pico-map-row #:y 9 #:nonzero-tiles 70 #:sample-hex "00001616161616161616161640404040")
      (def-pico-map-row #:y 10 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000010101010")
      (def-pico-map-row #:y 11 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000010101010")
      (def-pico-map-row #:y 12 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000050505050")
      (def-pico-map-row #:y 13 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000060606060")
      (def-pico-map-row #:y 14 #:nonzero-tiles 48 #:sample-hex "00000000000000000000000070707070")
      (def-pico-map-row #:y 15 #:nonzero-tiles 32 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 16 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 17 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 18 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 19 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 20 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000030303030")
      (def-pico-map-row #:y 21 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000020202020")
      (def-pico-map-row #:y 22 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000020202020")
      (def-pico-map-row #:y 23 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000020202020")
      (def-pico-map-row #:y 24 #:nonzero-tiles 16 #:sample-hex "00000000000000000000000020202020"))
    (sfx-tracks
      (def-pico-sfx #:id 0 #:editor-mode 101 #:speed 12 #:loop (0 8) #:active-notes 8)
      (def-pico-sfx #:id 1 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id 2 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 21)
      (def-pico-sfx #:id 3 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 4 #:editor-mode 101 #:speed 12 #:loop (0 8) #:active-notes 8)
      (def-pico-sfx #:id 5 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 6 #:editor-mode 101 #:speed 12 #:loop (0 8) #:active-notes 8)
      (def-pico-sfx #:id 7 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 8 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 24)
      (def-pico-sfx #:id 9 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 10 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 23)
      (def-pico-sfx #:id 11 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 24)
      (def-pico-sfx #:id 12 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 24)
      (def-pico-sfx #:id 13 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 20)
      (def-pico-sfx #:id 14 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 24)
      (def-pico-sfx #:id 15 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 28)
      (def-pico-sfx #:id 16 #:editor-mode 101 #:speed 12 #:loop (0 8) #:active-notes 8)
      (def-pico-sfx #:id 17 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 24)
      (def-pico-sfx #:id 18 #:editor-mode 101 #:speed 12 #:loop (0 32) #:active-notes 32)
      (def-pico-sfx #:id 19 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 26)
      (def-pico-sfx #:id 20 #:editor-mode 41 #:speed 12 #:loop (0 32) #:active-notes 26)
      (def-pico-sfx #:id 21 #:editor-mode 17 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 22 #:editor-mode 101 #:speed 12 #:loop (0 0) #:active-notes 32))
    (music-patterns
      (def-pico-music #:pattern 0 #:flags 0 #:channels (0 66 67 68))
      (def-pico-music #:pattern 1 #:flags 0 #:channels (0 66 67 68))
      (def-pico-music #:pattern 2 #:flags 0 #:channels (0 66 1 68))
      (def-pico-music #:pattern 3 #:flags 0 #:channels (0 66 2 68))
      (def-pico-music #:pattern 4 #:flags 0 #:channels (0 3 1 68))
      (def-pico-music #:pattern 5 #:flags 0 #:channels (4 5 2 68))
      (def-pico-music #:pattern 6 #:flags 0 #:channels (6 7 1 68))
      (def-pico-music #:pattern 7 #:flags 0 #:channels (4 8 2 68))
      (def-pico-music #:pattern 8 #:flags 0 #:channels (0 3 1 68))
      (def-pico-music #:pattern 9 #:flags 0 #:channels (4 5 2 68))
      (def-pico-music #:pattern 10 #:flags 0 #:channels (6 7 1 68))
      (def-pico-music #:pattern 11 #:flags 0 #:channels (4 9 10 68))
      (def-pico-music #:pattern 12 #:flags 0 #:channels (0 87 1 11))
      (def-pico-music #:pattern 13 #:flags 0 #:channels (4 88 2 12))
      (def-pico-music #:pattern 14 #:flags 0 #:channels (0 87 1 11))
      (def-pico-music #:pattern 15 #:flags 0 #:channels (4 88 2 13))
      (def-pico-music #:pattern 16 #:flags 0 #:channels (6 89 1 14))
      (def-pico-music #:pattern 17 #:flags 0 #:channels (0 87 1 15))
      (def-pico-music #:pattern 18 #:flags 0 #:channels (16 66 1 17))
      (def-pico-music #:pattern 19 #:flags 0 #:channels (18 66 19 20))
      (def-pico-music #:pattern 20 #:flags 0 #:channels (0 3 1 68))
      (def-pico-music #:pattern 21 #:flags 0 #:channels (4 5 2 68))
      (def-pico-music #:pattern 22 #:flags 0 #:channels (6 7 1 68))
      (def-pico-music #:pattern 23 #:flags 0 #:channels (4 8 10 68))
      (def-pico-music #:pattern 24 #:flags 0 #:channels (0 3 1 68))
      (def-pico-music #:pattern 25 #:flags 0 #:channels (4 5 2 68))
      (def-pico-music #:pattern 26 #:flags 0 #:channels (6 7 1 68))
      (def-pico-music #:pattern 27 #:flags 0 #:channels (4 9 19 68))
      (def-pico-music #:pattern 28 #:flags 0 #:channels (0 21 1 68))
      (def-pico-music #:pattern 29 #:flags 0 #:channels (0 66 1 68))
      (def-pico-music #:pattern 30 #:flags 0 #:channels (0 66 67 68))
      (def-pico-music #:pattern 31 #:flags 0 #:channels (22 66 67 68))
      (def-pico-music #:pattern 32 #:flags 0 #:channels (41 66 67 68))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      "-- mOT'S gRAND pRIX pLUS"
      "-- bY mOT"
      "-- tITLE aRT BY mARCO vALE"
      ""
      "glob={"
      "\t[\"true\"]=true,"
      "\t[\"false\"]=false"
      "}"
      ""
      "function dataint(lines,props,globname)"
      " local d={}"
      " for l in all(lines) do"
      "  local o,v={},split(l)"
      "  for i,val in ipairs(v) do"
      "   if val~=\"\" then"
      "    if(glob[val]~=nil)val=glob[val]"
      "\t   o[props[i]]=val"
      "\t  end"
      "  end"
      "  if o.name then"
      "  \td[o.name]=o"
      "  \tif(globname)glob[globname..\".\"..o.name]=o"
      "\t\tend"
      "  add(d,o)"
      " end"
      " return d"
      "end"
      ""
      "function data(str,globname)"
      " local lines=split(str,chr(10))"
      " local props=split(deli(lines,1))"
      " return dataint(lines,props,globname)"
      "end"
      ""
      "function datahdr(propstr,str,globname)"
      " return dataint(split(str,chr(10)),split(propstr),globname)"
      "end"
      ""
      "function sort(array,compfn)"
      " for i=2,#array do"
      "  local c,j=array[i],i"
      "  while j>1 and compfn(array[j-1],c) do"
      "   array[j]=array[j-1]"
      "   j-=1"
      "  end"
      "  array[j]=c"
      " end"
      "end"
      ""
      "-- shared animation code"
      "-- tHIS TAB CONTAINS ALL CODE "
      "-- NECESSARY TO LOAD AND PLAY"
      "-- ANIMATIONS."
      ""
      "-- constants"
      "animfilever=1"
      ""
      "-- routines"
      ""
      "function runcoroutines(co)"
      "\tfor c in all(co) do"
      "\t\tif costatus(c)==\"dead\"then"
      "\t\t\tdel(co,c)"
      "\t\telse"
      "\t\t\tassert(coresume(c))"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function lerp(a,b,f)"
      " return (1-f)*a+f*b"
      "end"
      ""
      "easefn={"
      " function(v) return v end,"
      " function(v) return  -sin(v/4) end,"
      " function(v) return 1-cos(v/4) end,"
      " function(v) return 0.5-cos(v/2)/2 end"
      "}"
      ""
      "function clamp(v,mn,mx)"
      "\treturn min(max(v,mn),mx)"
      "end"
      ""
      "function sprcoords(n)"
      "\treturn (n%16)*8,flr(n/16)*8"
      "end"
      ""
      "function tilecoords(n)"
      " return n%128,flr(n/128)"
      "end"
      ""
      "function smap(cx,cy,cw,ch,sx,sy,sw,sh,flipx,flipy)"
      " -- delta"
      " local dx,dy=cw/sw,ch/sh"
      " "
      " -- apply flip"
      " if flipx then"
      "  cx+=cw"
      "  dx=-dx"
      " end"
      " if flipy then"
      "  cy+=ch"
      "  dy=-dy"
      " end"
      " "
      " local x0,x1=sx,sx+sw"
      " local y0,y1=sy,sy+sh"
      " cx+=(ceil(x0)-x0)*dx"
      " cy+=(ceil(y0)-y0)*dy"
      " x0,y0,x1,y1=ceil(x0),ceil(y0),ceil(x1)-1,ceil(y1)-1"
      ""
      " -- render with tlines"
      " for y=y0,y1 do"
      "  tline(x0,y,x1,y,cx,cy,dx,0)"
      "  cy+=dy"
      " end"
      "end"
      ""
      "-- file i/o"
      ""
      "-- stream helpers"
      ""
      "function read2(self)"
      " return self:read1()|(self:read1()<<8)"
      "end"
      ""
      "-- memory stream"
      ""
      "function mem_size(self)"
      "\treturn self.addr-self.baseaddr"
      "end"
      ""
      "function mem_r1(self)"
      " local v=peek(self.addr)"
      " self.addr+=1"
      " return v"
      "end"
      ""
      "function readmemstream(addr)"
      "\treturn {"
      "\t\tbaseaddr=addr,"
      "\t\taddr=addr,"
      "\t\tsize=mem_size,"
      "\t\tread1=mem_r1,"
      "\t\tread2=read2"
      "\t}"
      "end"
      ""
      "-- hex string stream"
      ""
      "function fromhexchar(c)"
      " return ord(c)-(c>\"9\" and 87 or 48)"
      "end"
      ""
      "function str_size(self)"
      "\treturn #self.str/2"
      "end"
      ""
      "function str_r1(self)"
      " local str,offs=self.strs[flr(self.offs>>10)+1],self.offs&0x3ff"
      " offs+=1"
      " local hi=fromhexchar(sub(str,offs,offs))"
      " offs+=1"
      " local lo=fromhexchar(sub(str,offs,offs))"
      " self.offs+=2"
      " return (hi<<4)|lo"
      "end "
      ""
      "function readstrstream(strs)"
      "\treturn {"
      "\t\tstrs=strs,"
      "\t\toffs=0,"
      "\t\tsize=str_size,"
      "\t\tread1=str_r1,"
      "\t\tread2=read2"
      "\t}"
      "end"
      ""
      "-- helper functions"
      ""
      "function readstrfixed(stream,len)"
      "\tlocal result=\"\""
      "\tfor i=1,len do"
      "\t\tresult..=chr(stream:read1())"
      "\tend"
      "\treturn result"
      "end"
      ""
      "function readstr(stream)"
      "\tlocal len=stream:read1()"
      "\treturn readstrfixed(stream,len)"
      "end"
      ""
      "-- file io"
      ""
      "function loadanims(stream)"
      "\tprinth(\"*** loading animations ***\")"
      ""
      "\t-- verify header and version"
      "\tlocal hdr=readstrfixed(stream,3)"
      "\tif hdr~=\"mas\" then"
      "\t\tprinth(\"'mas' header not found\")"
      "\t\tstop()"
      "\tend"
      "\t"
      "\tlocal ver=stream:read1()"
      "\tif ver>animfilever then"
      "\t\tprinth(\"unsupported file version: \"..ver)"
      "\t\tstop()"
      "\tend"
      "\t"
      "\t-- load each animation"
      "\tlocal ct=stream:read1()"
      "\tlocal anims={}"
      "\tfor i=1,ct do"
      "\t\tlocal typ=stream:read1()"
      "\t\tlocal anim"
      "\t\tif typ==1 then"
      "\t\t\tanim=loadspriteanim(stream)"
      "\t\telse"
      "\t\t anim=loadtlanim(stream,typ)"
      "\t\tend"
      "\t\tadd(anims,anim)"
      "\t\tanims[anim.name]=anim"
      "\tend"
      "\t"
      "\t-- convert indices into references"
      "\tfor anim in all(anims) do"
      "\t if anim.typ~=\"sprite\" then"
      "\t  for tl in all(anim.tls) do"
      "\t   for k in all(tl.keyframes) do"
      "\t    k.anim=k.anim and anims[k.anim]"
      "\t   end"
      "\t  end"
      "\t end"
      " end"
      ""
      "\treturn anims"
      "end"
      ""
      "function loadspriteanim(stream)"
      "\tlocal anim=makespriteanim()"
      "\t"
      "\t-- properties"
      "\tanim.name=readstr(stream)"
      "\tanim.fps=stream:read1()/4"
      "\tanim.w=stream:read1()"
      "\tanim.h=stream:read1()"
      "\tanim.ox=stream:read1()/100"
      "\tanim.oy=stream:read1()/100"
      "\tanim.tr=stream:read1()"
      ""
      "\t-- frames"
      "\tanim.frames={}"
      "\tlocal ct=stream:read1()"
      "\tfor i=1,ct do"
      "\t\tlocal frame={}"
      "\t\tframe.frame=stream:read2()"
      "\t\tlocal flags=stream:read1()"
      "\t\tframe.flipx=(flags&1)==1"
      "\t\tframe.flipy=(flags&2)==2"
      "\t\tadd(anim.frames,frame)"
      "\tend"
      "\t"
      "\treturn anim   "
      "end"
      ""
      "function loadtlanim(stream,typ)"
      " local anim=maketlanim()"
      " if(typ==3)anim.typ=\"storyboard\""
      " "
      "\t-- properties"
      "\tanim.name=readstr(stream)"
      "\tanim.d=stream:read2()/100"
      "\t"
      "\t-- timelines"
      "\tanim.tls={}"
      "\tlocal ct=stream:read1()"
      "\tfor i=1,ct do"
      "\t local keyframes={}"
      "\t local kct=stream:read1()"
      "\t for j=1,kct do"
      "\t "
      "\t  -- time"
      "\t  local t=stream:read2()/100"
      "\t  local k=makekeyframe(t)"
      "\t  "
      "\t  -- content "
      "\t  local flags=stream:read1()"
      "\t  if (flags&1)~=0 then "
      "\t  \tk.anim=stream:read1()\t\t-- will be converted to object reference later"
      "\t\t\tend"
      "\t  if (flags&2)~=0 then"
      "\t  \tk.x=stream:read2()"
      "\t  \tk.y=stream:read2()"
      "\t  end"
      "\t  if (flags&4)~=0 then"
      "\t   k.xscale=stream:read2()/100"
      "\t   k.yscale=stream:read2()/100\t   "
      "\t  end"
      "\t  if (flags&8)~=0 then"
      "\t   k.animt=stream:read2()/100"
      "\t   k.animspd=stream:read2()/100"
      "\t  end "
      "\t  "
      "\t  -- state flags"
      "\t  flags=stream:read1()"
      "\t  k.flipx=(flags&1)~=0"
      "\t  k.flipy=(flags&2)~=0"
      "\t  k.visible=(flags&4)~=0"
      "\t  k.loop=(flags&8)~=0"
      "\t  k.easein=(flags&16)~=0"
      "\t  k.easeout=(flags&32)~=0"
      "\t  "
      "\t  k.tag=stream:read1()"
      "\t  "
      "\t  add(keyframes,k)"
      "\t end"
      "\t add(anim.tls,{keyframes=keyframes})\t "
      "\tend"
      "\t"
      "\t-- events"
      "\tanim.events.keyframes={}"
      "\tlocal ct=stream:read1()"
      "\tfor i=1,ct do"
      "\t"
      "  -- time"
      "  local t=stream:read2()/100"
      "\t local k=makeevent(t)"
      "\t "
      "\t -- type"
      "\t k.typ=readstr(stream)"
      "\t local flags=stream:read1()"
      "\t if (flags&1)~=0 then"
      "  \tk.x=stream:read2()"
      "  \tk.y=stream:read2()\t \t"
      "  end"
      "  if (flags&2)~=0 then"
      "   k.n=stream:read1()"
      "  end"
      "  if (flags&4)~=0 then"
      "   k.txt=readstr(stream)"
      "  end\t "
      "  add(anim.events.keyframes,k)"
      "\tend"
      "\t"
      "\treturn anim"
      "end"
      ""
      "-- sprite animations"
      ""
      "function drawanim("
      "\t\tself,"
      "\t\tt,"
      "\t\tx,y,"
      "\t\txscale,yscale,"
      "\t\tflipx,flipy,"
      "\t\tdt)"
      "\t\t"
      " self:dodraw("
      " \tt or 0,"
      " \tx or 64,"
      " \ty or 64,"
      " \txscale or 1,"
      " \tyscale or 1,"
      " \tflipx,"
      " \tflipy,"
      " \tdt or 1/(_update and 30 or 60),"
      " \t0)"
      "end"
      ""
      "function spriteanim_draw(self,t,x,y,xscale,yscale,flipx,flipy)"
      ""
      "\t-- find frame"
      "\tlocal f=clamp(flr(t*self.fps)+1,1,#self.frames)"
      "\tlocal frame=self.frames[f]"
      ""
      "\t-- display width and height"
      "\tlocal dw,dh=self.w*8*xscale,self.h*8*yscale"
      "\t"
      "\t-- flip flags"
      "\tif(frame.flipx)flipx=not flipx"
      "\tif(frame.flipy)flipy=not flipy"
      ""
      "\t-- adjust for orgin pt"
      "\tx-=dw*(flipx and (1-self.ox) or self.ox)"
      "\ty-=dh*(flipy and (1-self.oy) or self.oy)"
      ""
      "\t-- draw"
      "\t-- as tilemap coords"
      "\tpalt(0,false)"
      "\tpalt(self.tr,true)"
      "\tlocal cx,cy=tilecoords(frame.frame)"
      "\tsmap("
      "\t cx,cy,"
      "\t self.w,self.h,"
      "\t x,y,"
      "\t dw,dh,"
      "\t flipx,flipy)"
      " palt(self.tr,false)\t"
      "\tpalt(0,true)"
      "end"
      ""
      "function spriteanim_duration(self)"
      "\treturn #self.frames/self.fps"
      "end"
      ""
      "function makespriteanim()"
      "\treturn {"
      "\t\ttyp=\"sprite\","
      "\t\tname=\"sprite\","
      "\t\tfps=10,"
      "\t\tw=1,h=1,"
      "\t\tox=0.5,oy=0.5,"
      "\t\ttr=16,"
      "\t\tframes={"
      "\t\t\tmakespriteframe(1),"
      "\t\t},"
      "\t\tduration=spriteanim_duration,"
      "\t\tdodraw=spriteanim_draw,"
      "\t\tdraw=drawanim"
      "\t}"
      "end"
      ""
      "function makespriteframe(n)"
      "\treturn {"
      "\t\tframe=n--,"
      "--\t\tflipx=false,"
      "--\t\tflipy=false"
      "\t}"
      "end"
      ""
      "-- timelined animations"
      ""
      "function tlanim_duration(self)"
      "\treturn self.d"
      "end"
      ""
      "keyframeswitch=split(\"anim,animt,animspd,tag\")"
      "keyframelerp=split(\"x,y,xscale,yscale\")"
      "keyframeflags=split(\"flipx,flipy,visible,loop\")"
      ""
      "function findrefkeyframes(tl,prop,t)"
      " -- find nearest frames before/after t"
      " -- where property is not null"
      " local before,after"
      " local beforet,aftert=-1000,1000"
      " for k in all(tl.keyframes) do"
      "  if k[prop] then"
      "   if k.t<=t and k.t>beforet then"
      "    before,beforet=k,k.t"
      "   end"
      "   if k.t>t and k.t<aftert then"
      "    after,aftert=k,k.t"
      "   end"
      "  end"
      " end"
      " return before,after"
      "end"
      ""
      "function getvirtualkeyframe(tl,t)"
      ""
      " -- calculate the effective "
      " -- \"virtual\" keyframe at time t"
      " -- on the timeline, interpolating"
      " -- as necessary."
      " local props={"
      "  visible=true,"
      "  animt=0,animspd=1,"
      "  x=0,y=0,"
      "  xscale=1,yscale=1,"
      "  flipx=false,flipy=false,"
      "  easein=false,easeout=false"
      " }"
      ""
      "\t-- switchover properties"
      " local animtt\t\t\t\t"
      "\tfor prop in all(keyframeswitch) do"
      "\t before,after=findrefkeyframes(tl,prop,t)"
      "\t local frame=before or after"
      "\t if(frame)props[prop]=frame[prop]"
      "\t\tif prop==\"animt\" then"
      "\t\t animtt=before and before.t"
      "\t\tend"
      "\tend"
      ""
      "\t-- interpolated properties"
      "\tfor prop in all(keyframelerp) do"
      "\t before,after=findrefkeyframes(tl,prop,t)"
      "  if before and after then"
      "   local f=(t-before.t)/(after.t-before.t)"
      "   if prop==\"x\" or prop==\"y\" then"
      "    local e=1"
      "    if(after.easein)e+=1"
      "    if(before.easeout)e+=2"
      "    f=easefn[e](f)"
      "   end"
      "   props[prop]=lerp(before[prop],after[prop],f)"
      "  else"
      "\t\t local frame=before or after"
      "\t\t if(frame)props[prop]=frame[prop]"
      "\t\tend\t\t\t  "
      "\tend"
      "\t"
      "\t-- flags"
      "\tbefore,after=findrefkeyframes(tl,\"t\",t)"
      "\tlocal k=before or after"
      "\tif k then "
      "\t for prop in all(keyframeflags) do"
      "\t  props[prop]=k[prop]"
      "\t end"
      "\tend"
      "\t"
      "\t-- calculate effective animt"
      "\t-- at time t, taking into account"
      "\t-- animation speed an looping."
      "\tif animtt then"
      "\t props.animt+=(t-animtt)*props.animspd"
      "\tend"
      "\tif props.loop and props.anim then"
      "\t props.animt%=props.anim:duration()"
      "\tend"
      "\treturn props"
      "end"
      ""
      "function tlanim_draw(self,t,x,y,xscale,yscale,flipx,flipy,dt,r)"
      " -- recursion limit"
      " r+=1"
      " if(r>10) return"
      " "
      " -- draw anims for each timeline"
      " for tl in all(self.tls) do"
      ""
      "  -- get effective keyframe for t"
      "\t\tlocal props=getvirtualkeyframe(tl,t)"
      "\t\t"
      "\t\t-- draw child animation"
      "\t\tif props.visible and props.anim then"
      "\t\t"
      "\t\t -- calculate effective position,scale and flip"
      "\t\t local cx=x+props.x*xscale*(flipx and -1 or 1)"
      "\t\t local cy=y+props.y*yscale*(flipy and -1 or 1)"
      "\t\t local cxscale,cyscale=xscale*props.xscale,yscale*props.yscale"
      "\t\t local cflipx,cflipy=flipx,flipy"
      "   if(props.flipx)cflipx=not cflipx"
      "   if(props.flipy)cflipy=not cflipy"
      "   local cdt=dt and dt*props.animspd"
      "\t\t "
      "\t\t -- draw"
      "\t\t if not anim_draw or anim_draw(props,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r) then"
      "\t\t\t props.anim:dodraw(props.animt,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r)"
      "\t\t\tend"
      "\t\tend\t\t"
      "\tend"
      "\t"
      "\t-- trigger events"
      "\tif dt then"
      "\t for k in all(self.events.keyframes) do"
      "\t  if k.t>t-dt and k.t<=t and anim_events[k.typ] then"
      "    anim_events[k.typ](k,x,y)"
      "\t  end"
      "\t end"
      "\tend\t"
      "end"
      ""
      "function makekeyframe(t)"
      "\treturn {"
      "\t\tt=t,"
      "\t\tanim=nil,"
      "\t\tloop=true,"
      "\t\tafter=false,"
      "--\t\tanimt=nil,"
      "--\t\tanimspd=nil,"
      "--\t\tx=nil,"
      "--\t\ty=nil,"
      "--\t\txscale=nil,"
      "--\t\tyscale=nil,"
      "\t\tvisible=true,"
      "\t\tflipx=false,"
      "\t\tflipy=false,"
      "\t\teasein=false,"
      "\t\teaseout=false,"
      "\t\ttag=0"
      "\t}"
      "end"
      ""
      "function makeevent(t,typ)"
      " return {"
      "  t=t,"
      "  typ=\"\"--,"
      "--  x=nil,"
      "--  y=nil,"
      "--  n=nil,"
      "--  txt=nil"
      " }"
      "end"
      ""
      "function maketl()"
      ""
      " -- default keyframe"
      " local k=makekeyframe(0)"
      " k.animt,k.animspd,k.x,k.y=0,1,0,0"
      " "
      "\treturn {"
      "\t\tkeyframes={k}\t"
      "\t}"
      "end"
      ""
      "function maketlanim()"
      "\treturn {"
      "\t\ttyp=\"tl\","
      "\t\tname=\"timeline\","
      "\t\td=10,"
      "\t\ttls={ maketl() },"
      "\t\tevents={ keyframes={} },"
      "\t\tduration=tlanim_duration,"
      "\t\tdodraw=tlanim_draw,"
      "\t\tdraw=drawanim"
      "\t}"
      "end"
      ""
      "-- events"
      ""
      "do "
      " local afterframeco={}"
      "\tlocal function doafterframe(fn)"
      "\t\t add(afterframeco,cocreate(fn))"
      " end"
      " "
      " anim_events={"
      "  sfx=function(ev)\tsfx(ev.n)         end,"
      "  mus=function(ev) music(ev.n or -1) end,"
      "  txt=function(ev)"
      "   doafterframe(function()"
      "    for i=1,ev.n or 30 do"
      "     print(ev.txt,ev.x,ev.y)"
      "     yield()"
      "    end"
      "   end)"
      "\t\tend,"
      "  reltxt=function(ev,x,y)"
      "   doafterframe(function()"
      "    for i=1,ev.n or 30 do"
      "     print(ev.txt,x+(ev.x or 0),y+(ev.y or 0))"
      "     yield()"
      "    end"
      "   end)"
      "\t\tend,"
      "\t\tclr=function()"
      "\t\t afterframeco={}"
      "\t\tend,"
      ""
      "\t\t-- schedule code to execute after the frame"
      "\t\t-- can use yield() to execute after multiple frames"
      "\t\tdoafterframe=doafterframe,"
      "  "
      "  -- call this after the frame is rendered"
      "\t\tframedone=function()"
      "\t\t runcoroutines(afterframeco)"
      "\t\tend"
      " }"
      "end"
      "-->8"
      "-- data/constants"
      ""
      "-- constants"
      "type_race,type_tour,type_prac=1,2,3"
      ""
      "-- data"
      "tracknames=split(\"bRANDS hATCH,hOCKENHEIM,mONZA,sILVERSTONE,sPA fRANCORCHAMPS,sUZUKA\")"
      "racetypenames=split(\"sINGLE rACE,cHAMPIONSHIP,pRACTICE\")"
      "racetypeanims=split(\"race,tou,prac\")"
      "difnames=split(\"eASY,mEDIUM,hARD,eXPERT\")"
      "lapoptions=split(\"1,3,5,10,20\")"
      "racepts=split(\"15,12,10,8,6,4,2,1\")"
      "frame=0"
      ""
      "pals=data("
      "[[2,3,10,11,14"
      "131,140,2,139,3"
      "5,5,5,5,5]])"
      ""
      "aicarnames=split(\"s. hUDSON,d. vELOPER,h. pOTTER,v. iCE,p. bRAGA,m. pOWER,m. cRAB,r. bRUNT,z. lEX,d. sEEBS,b. aSTRO,s. hEINRICH,l. gARCIA,s. cAT\")"
      ""
      "aicarpals=data("
      "[[7,9,4"
      "0,11,0"
      "0,8,0"
      "15,4,1"
      "8,15,8"
      "4,9,4"
      "6,0,1"
      "6,7,6"
      "7,9,4"
      "1,13,7"
      "9,8,8"
      "7,14,2"
      "7,8,4"
      "10,14,1"
      "7,3,1]])"
      ""
      "animdata={"
      "\"6d6173012d01046269726417010132320c044800004900004900004900000109626f6172646261636b280c0a32000c012c00000103636172280a0432640c010200000105636c6f7564280301323210019000000106636c6f756473280803320010010c000001056772616e64280e0432320c014a00000107686f72697a6f6e28100a320010018c070001046d6f747328030132320c014a020001047072697828090432320c015800000104726f6164281007323210010c04000105726f616432281007323210011c04000103736b7928101032321001380000010474657874280a053200100182020001057465787432280a050000100182020001057472656573281005326410018c01000106747265657332281005326410019c010003057374617274c201010300000b1600000000000064000400c8000917000064000400dc000924000064000400000203626731e803050100000b070000c0ff000064000c000100000b050000c0ff000064000c000100000b0f0000f0ff000064000c010100000b0f00001000000064000c000100000b0a00002400000064000c00010000046772617902020207626731616e696db80b020100000b1200000000000064000c000600000b01c2ffceff000064000c00f40106f6ffcaff64005a000c00e803060e00d5ff320032001800270507150f00bdff64005a000c00d606022200c9\","
      "\"ff0c000009024d00c9ff0800000203626732e803060100000b070000c0ff000064000c000100000b05e6ffcdff000064000d000100000b042300ddff000064000c000100000b100000f0ff000064000c010100000b1000001000000064000c000100000b0b00002400000064000c000002056269726473c800030100000b0100000000000064000c000100000b01f7fffdff0a0064000c000100000b010500faff780064000c00000205626c616e6bc800010100000a00000000000064000c0000020666616465696e1400010100000a00000000000064000c00010a000366696e00020469646c656400020100000b1e00000000000064000c0c0100000b1900001400000064000c000002046d656e75e803010100000b0d00000000000064000c1e0002087072616369646c65e803020100000b1200000000000064000c000100000b250000000064006400040000020670726163696e6400020100000b1200000000000064000c000100000b2500000000000064000400000207707261636f75746400010200000f120000000064006400000064000c00640004200320030c0000020770726163707265e803010100000b1200000000000064000c000002087261636569646c656400030100000b1200000000000064000c000100000b0300001000000064000c000100000b25000000006400640004000002067261636569\","
      "\"6e6400030100000b1200000000000064000c000200000f030000100004000400000064000c00640004640064000c000100000b2500000000000064000400000207726163656f75746400010100000b1e00000000000064000c00000207726163657072656400010100000b1200000000000064000c0000020673636f7265736400010100000b0e00000000000064000c1f00020773636f726573661400010200000b22000000000000640008000a00000c0000020973746172746d61696ee600020300000b2100000000000064000c0a6400091f00006400040bc800091e000064000c0c0300000b1900000000000064000800af0002000040000c00e60002000014001c000002057469746c656400030319000b0680ffcfff000064000c004b00020000cfff1c0000000008000328000b098000e1ff000064000c005a00020000e1ff1c000200000800021e000b081400b5ff000064000c004d00021400c5ff1c00000207746f756261636b6400020100000b1400000000000064000c000100000b020000c1ff000064000c00000207746f7569646c656400020100000b2600000000000064000c000100000b22d7ffc4ff000064000c00000205746f75696e6400020100000b2600000000000064000c000300000b23d7ffc4ff000064000800320008000096000c004b0008000064000c00000207746f756d61696ee80301\","
      "\"0100000b2700000000000064000c00000206746f756f75746400010100000b2700000000000064000400000206746f757072656400010100000b2600000000000064000c000002087472616e6c6566748c00030200000b2700000000000064002c164b00028000000018000400000b2180ff0000000064002c0a4b000200000000140b9600011e0c0c2300091f000064000c0b0100000b1900001400000064000c000002097472616e72696768748c00030200000b2100000000000064002c164b000280ff000018000400000b2b80000000000064002c0a4b000200000000140b960001270c0c23000928000064000c0b0100000b1900001400000064000c0000\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\","
      "\"\"}"
      "-->8"
      "-- main"
      ""
      "function _init()"
      " cartdata(\"mot_gpp\")"
      " "
      " -- load animations"
      " local stream=readstrstream(animdata)"
      " anims=loadanims(stream)"
      " anim_events.fin=fadein"
      ""
      " -- load cart data"
      " "
      " -- game state"
      " if dget(10)==0 then"
      "\t\tracetype,dif,lapoption,tracknum=1,2,2,1"
      "\telse\t\t"
      "\t racetype\t=dget(10)"
      " \tdif\t\t\t\t\t\t=dget(11)"
      "\t tracknum\t=dget(12)"
      " \tlapoption=dget(13)"
      " end"
      " "
      " -- tournament state"
      " loadtournament()"
      ""
      " -- update tournament stats with last race results"
      " if  dget(30)==1\t\t\t\t\t         -- race ended "
      " and dget(18)==0 \t\t\t\t         -- not demo mode"
      " and racetype==type_tour then\t"
      " \tapplyraceresults()"
      " end  "
      " dset(30,0)"
      " "
      " -- menu initial state"
      " mode,menui,menuy,demo,democtr=\"title\",0,0,false,3150"
      " "
      " -- play start animation"
      " local animset=getmodeanimset(racetype)"
      " animsets={animset}"
      " transition(anims[\"start\"],anims[\"idle\"])"
      " "
      " -- fade in music"
      " music(0,5000) "
      "end"
      ""
      "function _draw()"
      " cls()"
      " basepal()"
      " if(anim and animt)anim:draw(animt)"
      " if(confirmprompt)drawconfirm()"
      " drawfade()"
      "end"
      ""
      "function _update()"
      " frame+=1"
      " "
      " -- can't update while transitioning"
      " if not istransition then"
      "  if confirmprompt then"
      "   updateconfirm()"
      "  elseif mode==\"title\" then"
      "\t \tupdatemenu()"
      "\t end"
      "\tend"
      " "
      " -- drive animation"
      " if animt then "
      "\t animt+=1/30"
      "\t if istransition and animt>=anim:duration() then"
      "\t "
      "\t  -- end transition"
      "   if(doneanim)anim,animt=doneanim,0"
      "   if(donefn)donefn() "
      "   doneanim,donefn=nil,nil"
      "   istransition=false"
      "\t end"
      "\tend\t "
      ""
      " -- update fade\t"
      " updatefade()"
      "end"
      ""
      "function rungame(demo)"
      ""
      " if racetype==type_race then"
      " \troster=makerandomroster()"
      " elseif racetype==type_tour then"
      "  roster=tour.roster"
      " else"
      "  roster=nil"
      " end"
      ""
      " -- pass parameters to game"
      " -- stored in different data slots than used"
      " -- to persist values between sessions."
      " -- this is so demo can invoke a random track"
      " -- without overwriting user's prefs."
      " dset(14,racetype)"
      " dset(15,dif)"
      " dset(16,demo and 1 or lapoptions[lapoption])"
      " local tracki"
      " if racetype==type_tour then"
      "  tracki=tour.tracks[tour.tracknum]"
      " else"
      "  tracki=tracknum"
      "\tend"
      "\tdset(17,tracki)"
      " dset(18,demo and 1 or 0)"
      ""
      " -- pass roster"
      " if roster then"
      "\t for i,c in ipairs(roster) do"
      "\t  dset(19+i,c)"
      "\t end"
      "\tend"
      "\t"
      "\t-- unpack track data into high memory"
      "\tmemset(0x8000,0,0x7fff)"
      "\tlocal data=trackdata[tracki]"
      "\tfor i=1,#data do"
      "\t poke(0x8000+i-1,ord(data,i))"
      "\tend"
      " "
      " -- run game"
      " load(\"#mot_grandprix2game\")"
      "end"
      ""
      "animsetnames=split(\"pre,_in,idle,out\")"
      ""
      "function anim_draw(props,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r)"
      " local tag=props.tag"
      " if tag==1 then "
      " \tpal(pals[2])"
      " else"
      "  basepal()"
      " end"
      " "
      " if tag>=10 and tag<30 then"
      "  local animset=animsets[tag\\10]"
      "  local name=animsetnames[tag%10+1]"
      "  local anim=animset[name]"
      "\t anim:dodraw(props.animt,cx,cy,cxscale,cyscale,cflipx,cflipy,cdt,r)"
      "\t\treturn false"
      "\telseif tag==30 then"
      "\t camera(64-cx,-cy)"
      "\t drawmenu()"
      "\t camera()"
      "\t return false"
      "\telseif tag==31 then"
      "\t camera(-cx,-cy)"
      "\t drawleaderboard()"
      "\t camera()"
      "\t return false"
      " end"
      ""
      " return true"
      "end"
      ""
      "function drawconfirm()"
      " rectfill(0,50,128,77,3)"
      " rect(-1,50,128,77,7)"
      " cprint(confirmprompt,56,6)"
      " local selcol=frame%8<4 and 7 or 6"
      " pprint(\"yES\",50,67,confirmx==0 and selcol or 5)"
      " pprint(\"nO\", 69,67,confirmx==1 and selcol or 5)"
      "end"
      ""
      "function updateconfirm()"
      " if(btnp(⬅️))confirmx=0"
      " if(btnp(➡️))confirmx=1"
      " if btnp(❎)or btnp(🅾️) then"
      "  confirmprompt=nil"
      "  if confirmx==0 then"
      "   confirmfn()"
      "  end"
      "  confirmfn=nil"
      " end"
      "end"
      "-->8"
      "-- routines"
      ""
      "function fadein()"
      " fadepixels={}"
      " for i=0,63 do"
      "  sset(i%8,i\\8,0)"
      "  add(fadepixels,i)"
      " end"
      " fade=\"in\""
      "end"
      ""
      "function drawfade()"
      " if fade==\"in\" then"
      "  palt(0,false) palt(1,true)"
      "  for i=0,255 do"
      "   spr(0,i%16*8,i\\16*8)"
      "  end"
      "  if(#fadepixels==0)fade=nil"
      " end"
      "end"
      ""
      "function updatefade()"
      " if fade==\"in\" then"
      "  for k=1,2 do"
      "   local j=rnd(fadepixels)"
      "   del(fadepixels,j)"
      "  \tsset(j%8,j\\8,1)"
      "\t end"
      "\tend"
      "end"
      ""
      "function pprint(txt,x,y,c)"
      " for ox=-1,1 do"
      "  for oy=-1,1 do"
      "   print(txt,x+ox,y+oy,1)"
      "  end"
      " end"
      " print(txt,x,y,c or 6)"
      "end"
      ""
      "function cprint(txt,y,c)"
      " pprint(txt,65-#txt*2,y,c)"
      "end"
      ""
      "function mprint(txt,y,i)"
      " cprint(txt,y,menui==i and frame%8<4 and not istransition and not confirmprompt and 7 or 6)"
      "end"
      ""
      "function basepal()"
      " pal()"
      " pal(pals[1],1)"
      "\tpoke(0x5f2e,1)"
      "end"
      ""
      "function transition(_anim,_doneanim,_donefn)"
      " anim,doneanim,donefn=_anim,_doneanim,_donefn"
      " animt,istransition=0,true"
      "end "
      ""
      "function getmodeanimset(racetype)"
      " local modename=racetypeanims[racetype]"
      " return {"
      "  pre=anims[modename..\"pre\"],"
      "  _in=anims[modename..\"in\"],"
      "  idle=anims[modename..\"idle\"],"
      "  out=anims[modename..\"out\"]"
      " } "
      "end"
      ""
      "function makerandomroster(t,n)"
      " return randomnums(14,7)"
      "end"
      ""
      "function randomnums(t,n)"
      " local allnums={}"
      " for i=1,t do"
      "  add(allnums,i)"
      " end"
      " local result={}"
      " for i=1,n or t do"
      "  add(result,del(allnums,rnd(allnums)))"
      " end"
      " return result"
      "end"
      ""
      "function sort(array,compfn)"
      " for i=2,#array do"
      "  local c,j=array[i],i"
      "  while j>1 and compfn(array[j-1],c) do"
      "   array[j]=array[j-1]"
      "   j-=1"
      "  end"
      "  array[j]=c"
      " end"
      "end"
      ""
      "function confirm(prompt,fn)"
      " confirmprompt=prompt"
      " confirmfn=fn"
      " confirmx=1"
      "end"
      ""
      "-->8"
      "-- menu"
      ""
      "function drawgamename()"
      " rectfill(20,6,105,37,0)"
      " print(\"\\^pmOT'S\",44,10,7)"
      " print(\"\\^pgRAND pRIX\",24,25,7)"
      "end"
      ""
      "menu_type,menu_dif,menu_laps,menu_track,menu_start,menu_tour_start,menu_tour_quit=1,2,3,4,5,6,7"
      ""
      "function getmenuitems()"
      " local items={menu_type}"
      " if racetype~=type_prac then"
      "  add(items,menu_dif)"
      "  add(items,menu_laps)"
      " end"
      " if racetype==type_tour then"
      "  if tour.tracknum==0 or tour.tracknum>#tour.tracks then"
      "  \tadd(items,menu_tour_start)"
      "  else"
      "   add(items,menu_tour_quit)"
      "   if tour.tracknum>=1 and tour.tracknum<=#tracknames then"
      "    add(items,menu_start) "
      "   end"
      "  end"
      " else"
      "  add(items,menu_track)"
      "  add(items,menu_start) "
      " end"
      " return items"
      "end"
      ""
      "function drawmenu()"
      " local items=getmenuitems()"
      " local yoffs=(5-#items)*3"
      " palt(12,false)"
      " if not istransition and not confirmprompt then"
      "\t sspr(8,0,8,8,0,menuy*8-2+yoffs,128,9)"
      "\tend"
      " for i,item in ipairs(items) do"
      "  local txt,arrows=\"\",false"
      "  if     item==menu_type  then txt=racetypenames[racetype]         arrows=true"
      "  elseif item==menu_dif   then txt=\"dIFFICULTY: \"..difnames[dif]   arrows=true"
      "  elseif item==menu_laps  then txt=\"lAPS: \"..lapoptions[lapoption] arrows=true"
      "  elseif item==menu_track then txt=\"tRACK: \"..tracknames[tracknum] arrows=true"
      "  elseif item==menu_start then txt=\"!! rACE !!\""
      "  elseif item==menu_tour_start then txt=\"nEW cHAMPIONSHIP\""
      "  elseif item==menu_tour_quit  then txt=\"qUIT cHAMPIONSHIP\""
      "\t end"
      "\t local y=(i-1)*8+yoffs"
      "  mprint(txt,y,i-1)    "
      "  if arrows then"
      "   spr(114,6,y-1,1,1,true)"
      "   spr(114,114,y-1)"
      "  end"
      " end"
      "end"
      ""
      "function updatemenu()"
      " -- up/down arrows"
      " if(btnp(⬆️))menui-=1"
      " if(btnp(⬇️))menui+=1"
      ""
      " -- find current menu item"
      " local items=getmenuitems()"
      " menui=mid(0,#items-1,menui)"
      " local item=items[menui+1]"
      ""
      " -- left/right arrows"
      " local d=0"
      " if(btnp(⬅️))d-=1"
      " if(btnp(➡️))d+=1"
      ""
      " if item==menu_type and d~=0 then  "
      "  if racetype+d>=1 and racetype+d<=#racetypenames then"
      "\t\t\tlocal prevtype=racetype"
      "\t\t\tracetype+=d"
      "\t\t\tlocal animset,prevset=getmodeanimset(racetype),getmodeanimset(prevtype)"
      "\t\t\tanimsets={animset,prevset}"
      "\t\t\tlocal anim=d<0 and anims[\"tranleft\"] or anims[\"tranright\"]"
      "\t\t\ttransition(anim,anims[\"idle\"])"
      "  end"
      " end"
      " if(item==menu_dif)dif+=d"
      " if(item==menu_laps)lapoption+=d"
      " if(item==menu_track)tracknum+=d"
      " dif=mid(1,#difnames,dif)"
      " lapoption=mid(1,#lapoptions,lapoption)"
      " tracknum=mid(1,#tracknames,tracknum)"
      " "
      " dset(10,racetype)"
      " dset(11,dif)"
      " dset(12,tracknum)"
      " dset(13,lapoption)"
      ""
      " -- buttons"
      " if btnp(❎)or btnp(🅾️) then"
      "  if(item==menu_start)rungame(false)"
      "  if(item==menu_tour_start)newtournament()"
      "  if(item==menu_tour_quit)confirm(\"qUIT cHAMPIONSHIP?\",quittournament)"
      " end"
      " "
      " -- animate menu highlight"
      " if(menuy~=menui)menuy+=sgn(menui-menuy)/4"
      ""
      " -- demo counter "
      " if((btn()&0x3f)~=0)democtr=max(democtr,1800)"
      " democtr-=1"
      " if democtr<=0 then "
      "  demo=true"
      "\t\tracetype,dif,lapoption,tracknum=1,2,1,rnd(#tracknames)\\1+1"
      " \trungame(true) "
      " end"
      "end"
      ""
      "-->8"
      "-- debugging"
      ""
      "lines,s={},0 function dadd(n,v,i,p)while p>1 and lines[p-1].i==i and type(lines[p-1].n)==type(n)and lines[p-1].n>n do p-=1 end add(lines,{n=n,v=v,x=type(v)==\"table\"and\"+\"or\" \",i=i},p)end"
      "function dexp(l,p)if l.x==\"+\"then for n,v in pairs(l.v)do p+=1 dadd(n,v,l.i..\" \",p)end l.x=\"-\"elseif l.x==\"-\"then while p<#lines and #lines[p+1].i>#lines[p].i do deli(lines,p+1)end\tl.x=\"+\" end end"
      "function dinp()local x,y,b,w=stat(32),stat(33),stat(34),stat(36)line(x,y,x,y+2,10)if btnp(❎) then local i=(y-10)\\6+1 local p=s+i local l=lines[p]if l and(x-10)\\4==#l.i then dexp(l,p)end end s=max(min(s-stat(36),#lines-18),0) end"
      "function dui()while true do rectfill(10,10,118,118,1)for i=1,18 do local l=lines[i+s]if l then print(sub(\"\\fc\"..l.i..l.x..l.n..\":\\f7\"..tostr(l.v),1,31),10,(i-1)*6+10,7)end end dinp()flip()end end"
      "function dinsp(v)dadd(\"value\",v,\"\",#lines+1)poke(0x5f2d,3)cursor()pal()clip()dui()end"
      ""
      "-->8"
      "-- tournament"
      ""
      "function newtournament()"
      " tour.tracks=randomnums(#tracknames)"
      " tour.tracknum=1"
      " tour.roster=makerandomroster()"
      " tour.playerpts=0"
      " tour.pts={}"
      " for i=1,7 do"
      "  add(tour.pts,0)"
      " end"
      " savetournament()"
      " updateleaderboard()"
      " menui=4"
      " "
      " -- todo: animation"
      "end"
      ""
      "function quittournament()"
      ""
      " -- todo: confirmation prompt if tournament running"
      " tour.tracknum=0"
      " savetournament()"
      "end"
      ""
      "function loadtournament()"
      " tour={"
      "  tracknum=dget(40),"
      "  tracks={},"
      "  roster={},"
      "  pts={},"
      "  playerpts=0"
      " }"
      " if tour.tracknum>0 then"
      "  for i=1,#tracknames do"
      "   add(tour.tracks,dget(40+i))"
      "  end"
      "  for i=0,6 do"
      "   add(tour.roster,dget(50+i))"
      "   add(tour.pts,dget(57+i))"
      "  end"
      "  tour.playerpts=dget(49)"
      "  updateleaderboard() "
      " end "
      "end"
      ""
      "function savetournament()"
      " dset(40,tour.tracknum)"
      " if tour.tracknum>0 then"
      "  for i=1,#tracknames do"
      "   dset(40+i,tour.tracks[i])"
      "  end"
      "  for i=0,6 do"
      "   dset(50+i,tour.roster[i+1])"
      "   dset(57+i,tour.pts[i+1])"
      "  end"
      "  dset(49,tour.playerpts)"
      " end "
      "end"
      ""
      "function updateleaderboard()"
      " leaderboard={}"
      " for i,car in ipairs(tour.roster) do  "
      "  add(leaderboard,"
      "  \t{"
      "  \t name=aicarnames[car],"
      "  \t p=aicarpals[car],"
      "  \t pts=tour.pts[i]"
      "  \t})"
      " end"
      " add(leaderboard,{"
      " \t\tname=\"pLAYER\","
      " \t\tpts=tour.playerpts,"
      " \t\tisplayer=true"
      " \t})"
      " sort(leaderboard,function(a,b)return a.pts<b.pts end)"
      "end"
      ""
      "function drawleaderboard()"
      " print(\"driver\",0,1,5)"
      " print(\"points\",58,1,5)"
      " if(tour.tracknum==0)return"
      " for i,e in ipairs(leaderboard) do"
      "  local y,col=i*6+2,e.isplayer and 7 or 6"
      "  pal()"
      "  palt(0,false)"
      "  palt(12,true)"
      "  if(e.p)pal(e.p,0)"
      "  spr(8,0,y)"
      "  pal()"
      "\t\tprint(e.name,10,y,col)"
      "\t\tlocal txt=tostr(e.pts)\t\t"
      "\t\tprint(txt,82-#txt*4,y,col)"
      " end"
      " "
      " if tour.tracknum>#tour.tracks then"
      "  if frame%30<15 then"
      "\t  print(\"fINAL sTANDINGS\",12,60,7)"
      "\t end"
      " else"
      "  local tracknum=tour.tracks[tour.tracknum]"
      "  local trackname=tracknames[tracknum]"
      "  print(\"nEXT:\"..trackname,-2,60,7)"
      " end "
      "end"
      ""
      "function applyraceresults()"
      ""
      " -- player points"
      " local playerpos=dget(31)"
      " tour.playerpts+=racepts[playerpos]"
      ""
      " -- ai car points"
      " for i=1,7 do"
      "  local pos=dget(31+i)"
      "  tour.pts[i]+=racepts[pos]"
      " end"
      " "
      " -- advance to next track "
      " tour.tracknum+=1"
      "  "
      " savetournament() "
      " updateleaderboard() "
      "end"
      ""
      "-->8"
      "-- tracks"
      "trackdata={"
      "-- brands hatch"
      "\"²⁸³fin³(\\0=²\\0ャ⁸¹ᶠ¹\\r2\\0□ル¹ᵉ#\\0\\\"\\0¹ᶜ\\r⁘ヨ\\0d\\0⁘ヨ\\0X\\0⁸フ\\0F\\0□⁘\\0⁘\\0□⁘\\0、\\0□⁘\\0$\\0□⁘\\0*\\0」」\\0*\\0」⁘\\0⁵\\0。ᶠ\\0U\\0⁙ᶠ\\0d\\0⁴」³6\\0ᵇ\\0\\0b\\0³pdk⁷⁘\\0003¹\\0\\n¹ᵉ¹ᶜ゛\\0ᶠ\t\\0Fム⁘⁘\\0¹⁸\\0」\\0S⁴\\0ル¹ᶜ¹ぬ⁘\\0¹◝◝⁘\\0O¹\\0\\0ャ⁵²むス(\\0r\\0¹\\r¹\\r²ム⁘⁴◀ろ\\0A\\0「ろ\\0F\\0◀ウ\\0H\\0•\\0\\0🐱\\0³drd⁷-\\0_「\\0‖ロ⁘¹ᶜ¹ヌ゛\\0H⁸²フ⁘\\n\\0¹ュ◝⁘\\0ᵇ◝◝\\0゛•\\0¹ヨ◝(\\0rレ²ᶠᵉ¹ᵉ¹ヌ⁘\\0iュ◝⁸¹\\r¹ムᵉ「ヨ\\0ᶠ\\0□ヨ\\0⁸\\0¥⁸\\0⁙\\0¥⁸\\0 \\0¥⁸\\0-\\0¥⁸\\0:\\0¥ン\\0お\\0¥ン\\0し\\0、2\\0い\\0、2\\0♥\\0\\n<\\0n\\0□」\\0ゆ\\0□」◜ゆ\\0□」ュゆ\\0³sur\\r(\\0!ョ◝¹ᶜ⁘\\0)ョ◝#¹ᵉᶠ\\0¹◜◝⁘\\0タッ◝\\0⁸¹\\r¹#」\\0z\t\\n¹ᶠ¹ᶠ²ヨᶠ゛\\0@²ヨᶠ\\n\\0A³\\0²ヨᶠ#\\0B」²ヨᶠ\\n\\0N゛ャ⁵²ヨᶠ⁘\\0@²ヨᶠ⁘\\0Lロ\\n²ヨᶠ⁘\\0Bラ²ヨᶠᶠ\\0@²ヨᶠ\\n◀ᶠ\\0ᶠ\\0◀ᶠ\\0◀\\0「ᶠ\\0。\\0◀ᶠ\\0$\\0•\\0\\0ス\\0¥⁷\\0⌂\\0¥⁷\\0▥\\0¥⁷\\0ル\\0¥⁷\\0²¹¥ン\\0²¹³haw³⁘\\0uᵉ\\0ム¹\\r¹ᵉ²フᶠ⁘\\0Gᵉ\\0\\0ル³フᶠヌ2\\0`¹\\r²ムᶠ¹⁙ヨ\\0R\\0³wst⁸⁘\\0Aᶠ\\0²ヨᶠ」\\0C³\\0。²ヨᶠ⁘\\0C⁶\\0002²ヨ⁘⁘\\0Bフ²ヨ⁘#\\0C⁷\\0\\0²ヨᶠ⁘\\0Q⁷\\0¹ᶜ²ヨᶠᶠ\\0Oᵇ\\0ᵇムᶜ²ホ■(\\0N¥ロ\\n²ム■²¥⁸\\0き\\0¥⁸\\0て\\0⁴strl\tᶠ\\0Yリ◝⁘¹\\r²ヨ」ᶠ\\0Kリ◝\\0ᶜ²ヨ⁘<\\0B◀²ᶠヨ\\n\\0N\tャ⁵²ヨᶠ\\n\\0Bロ²ルᶜ⁘\\0Lヨ⁘¹ヤ⁘\\0P¹ᶠ¹マ(\\0C\t\\0ᵉ¹マ⁘\\0{⁴\\0\\0⁸¹ᶜ¹ᶜ¹ス⁴•\\0\\0g\\0¥⁸\\0K\\0¥ヲ\\0K\\0⁘フ\\0っ\\0³end²<\\0[⁴\\0モ⁵¹ᶠ¹ス」\\0/¹\\0\\0ヨ⁵¹\\r⁴「ツ\\0>\\0「ツ\\0D\\0□ツ\\0J\\0◀ツ\\0P\\0ᶜ⁴\","
      "-- hockenheim"
      "\"²⁷⁶finish¹x\\0004ル¹\\r¹\\r▮⁷ム\\0\\0\\0⁷ム\\0⁘\\0⁷ム\\0(\\0³フョ#\\0⁷ム\\0<\\0⁷ム\\0P\\0ᵇ\\0\\0002\\0。ᶜ\\0'\\0³▮³3\\0◀\\n\\0⁘\\0 ⁷ュ@\\0³▮³G\\0⁷ム\\0d\\0⁸ム\\0x\\0³▮³[\\0³▮³o\\0⁴nordᵉ!\\0」ᶜ\\0ᶜ¹ᶜᶜ\\0 ¹ᶜ⁘\\0⁴ヲᶠ\\0X⁵²ᶠ\\r²フ(⁘\\0p¹\\r¹\\r²ム⁘⁸\\0Dュ²ヨᶠ⁴\\0@²ルᶜ⁘\\0Lヲ\\n²ユ▮⁘\\0P¹ᶠ²ヨᶠd\\0A¹\\0²ルᵉd\\0Q²\\0¹\\r²レᵉ\\n\\0Lャ⁵²ロᶜ⁸\\0@²ルᶜ゛\\0H⁘²ヲ゛ᵉ⁷ム\\0\\n\\0⁷ム\\0゛\\0³▮³ᵇ\\0」ツ\\0゛\\0」ツ\\0#\\0⁷ム\\0002\\0¥⁸\\0*\\0¥⁸\\0002\\0¥⁸\\0:\\0•\\0\\0n\\0 ッョき\\0 ッョキ\\0」ム\\0⁴¹•\\0\\0m¹⁵clarkᶠᶜ\\0G⁘\\0⁷ム²ス(⁸\\0Dヌ²ス」ᵉ\\0Gヒ◝\\0ル²ク゛⁘\\0X⁸¹ᶜ²ツ゛-\\0Q²\\0¹\\r²ᶜツ(\\0A¹\\0²ᶜツ(\\0A¹\\0²ᶜツ(\\0A¹\\0²ᶜツ(\\0A¹\\0³ラᶜヌ\\n\\0Lャ⁵¹ᶜ⁸\\0@¹ロ\\n\\0\\\\ヲ⁸²ᶠ\\r²ルᶜ⁘\\0@²ルᶜ■\\0R\\n¹\\r²モᶜᶠ\\0V\\nヨ²ᶠ\\r²モᶜ▶⁷チ²ᶠ\\0⁙」\\0 \\0⁷ム¹(\\0⁷ム²<\\0⁷ム²P\\0⁷ム²d\\0⁷ム²x\\0 ヨ◜d\\0⁷ム²😐\\0⁷ム²き\\0⁷ム²ひ\\0⁷ム²っ\\0 ヨ◜ひ\\0▮リ\\0ふ\\0 ヨ◜ゆ\\0 ヨ◜っ\\0 ヨ◜キ\\0•\\0\\0ᵉ¹⁸ヤ²⁴¹ ッョ゜¹「レ\\0005¹◀レ\\0<¹ ッョD¹³ost▮ᶜ\\0W「\\0ᶠス¹ᶜ³スろᶜ\\n\\0F\tス²ろᶜ⁸\\0Gフ◝ロス³ᶜろ□\\n\\0¹\\r\\0⁘\\0G⁶\\0\\0ル³スᶜ□ᶠ\\0Q⁴\\0¹\\r²ラᶜ2\\0R⁴¹ᶜ²ラᶜ\\n\\0\\\\ャ⁵¹\\r²ルᶜ⁵\\0@²ᶜル\\n\\0Lヲ⁸²ルᶜ2\\0Bッ²ルᶜF\\0N⁴ヲ⁸²ルᶜ\\n\\0N\\0ャ⁵²ル\\n⁵\\0@²ロ\\n\\n\\0Lヲ⁸²ルᶜ⁘\\0dム¹ᶜ²フᶜ⁷⁸ウ\\0ᵉ\\0⁸ウ\\0「\\0•\\0\\0○\\0•\\0\\0¥¹■マ\\0-\\0▮ム\\0000\\0▮ヌ\\0*\\0⁵senna\t⁸\\0Mノ◝フᶜ²ネᵉ\\n\\0Lヌ•²ナ。□\\0i⁘\\0◀¹\\r²ウ゛\\n\\0Lモ⁸²ナ◀⁘\\0Eュ◝ヲ²モ\\n2\\0Bッ²ロ\\n2\\0B\t²ロ\\n2\\0Bᶜ²ロ\\n2\\0Bワ²ロ\\n²⁸タ¹「\\0▮フ\\0*\\0⁴agip⁷⁵\\0Lャ⁵¹ロ⁵\\0@¹ロ⁵\\0Lヲ⁸¹ロᶠ\\0@¹ルᶠ\\0p²ᶠ\\r²ᶠ\\r¹ホ゛\\0005ᶜ\\0ヌ¹ᶜ¹ᶜ7\\0\\0■•\\0\\0⁷\\0■⁘\\0\\\"\\0■¥\\0#\\0▮゜\\0#\\0■%\\0#\\0▮ᵉ\\0□\\0■ᵉッ□\\0⁷ス\\0>\\0\tᵉ²K\\0\tᵉ²_\\0\tᵉ²s\\0 ッョ\\\"\\0 ⁶ョ\\\"\\0」ゃ\\0D\\0」よ\\0L\\0⁷ス\\0Z\\0□ス\\0x\\0⁵sachs\\n#\\0■ム◝¹\\rᶠ\\0\tヨ◝ᶠᵉ\\0²⁷ᵇ\\0³リ◝ャ\\n\\0\\0ᵇ\\0¹ᶜ\\0ᶜ\\0\\0」\\0C■\\0\\0¹ろ\t\\0Bャ¹ろ#\\0Gᶠ\\0\\0ル¹ろᵉ\tᵉ²⁵\\0³⁘²⁵\\0◀」\\0 \\0◀」\\0&\\0゜<\\0007\\0▮⁘\\0。\\0▮」\\0。\\0□⁘\\0:\\0」゛\\0d\\0⁸エ\\0i\\0⁷ウ\\0x\\0⁷ウ\\0😐\\0⁷ツ\\0お\\0」ろ\\0て\\0¹²\","
      "-- autodromo nazionale monza"
      "\"²⁸³fin\\n(\\0<ャ⁴¹ᶠ¹ᶜ\\n\\0¹³\\0-\\0\\0(\\0\\0002\\0p²ᶠ\\r¹\\r¹ム⁘\\0\\0゛\\0@¹ワ゛\\0p¹ᶠ¹ᶠ¹ム\\n\\0 ¹ᶜ\\n\\0⁸ᶠ&³ラ³(\\0\tᶜ¹³\\0▮ᶜ\\0、\\0◀\\n\\0*\\0「ᶠ\\0*\\0「\\n\\0%\\0◀ᶠ\\0%\\0、⁸\\0004\\0⁸ロ¹ゆ\\0。⁸\\0♥\\0³ᶜ⁴き\\0ᵇ\\0\\0∧\\0¥⁶◝キ\\0¥⁶◝っ\\0¥⁶◝ゆ\\0\t\\n\\0ユ\\0▮\t\\0ヒ\\0⁙ヲ\\0\t¹ ョョミ\\0 ョョワ\\0 ョョ³¹\\n\\n\\0⁴¹\t⁸²A\\0\t⁸²U\\0\t⁸²i\\0\\n⁸²}\\0 ョョᶠ¹」ル\\0ᵉ¹⁙ワャ(\\0³ラ³<\\0³ラ³P\\0³ラ³d\\0³ラ³x\\0⁸ル\\0⁘¹³モ³\\0\\0▮ラ\\0、\\0▮モ\\0、\\0■ヨュ、\\0\trettifilo³\\n\\0⁵゜\\0ムᶜ\\0Eト◝ム¹。(\\0Lワ⁶¹」⁷⁙⁘\\0◀\\0⁙⁙\\0•\\0⁙■\\0!\\0⁷フ\\0#\\0⁷ヌ\\0⁸\\0▮■\\0<\\0⁷ム\\0007\\0⁸biassonoᶠᶠ\\0i⁶\\0⁵¹\\r¹ᵉᶠ\\0P¹\\r²ᵇヨ⁵\\0Dャ²ᵇヨ⁵\\0@²ᵇラ⁵\\0Dワ²ᵇラᶠ\\0@²ᵇラ゛\\0A⁴\\0¹ラ゛\\0Q⁵\\0¹ᶜ²リᶜ゛\\0Q⁴\\0¹ᶠ²ム□⁘\\0@²モ\\n」\\0P¹\\r²リ⁸\\n\\0Lャ⁵²リ\\n⁵\\0@²リ\\r⁵\\0Lッ⁸²ル\\r#\\0P¹ᶠ¹ᶜ⁵」⁶\\0⁵\\0•\\0\\0%\\0•\\0\\0エ\\0◀\\n\\0~\\0◀\\n\\0♥\\0⁶roggia⁷\\n\\0Dル¹\\r\\n\\0¹ト◝\\n\\0⁵•\\0ロ⁘\\0P¹ᶜ¹リ\\n\\0Mュ◝ャ⁵¹ル⁵\\0@²ロ\\n#\\0Tリ¹ᶠ²\\rヨ⁵\t⁘¹\\r\\0•\\0\\0:\\0\tᵉ¹$\\0 ッョI\\0¥ヲ\\0U\\0⁵lesmo⁶゛\\0Q\\r\\0¹ᵉ²ホ\\n゛\\0P¹ᶜ²ユ\\n⁘\\0P¹\\r²ユ\\n\\n\\0P¹ᶜ¹ユ⁘\\0Y■\\0ᶜ¹\\r¹ユ\\n\\0H⁶²ユᶠ³⁙ヤ\\0□\\0\\nᶜ²P\\0◀\\n\\0[\\0\tserraglioᵉ(\\0Lャ⁵²ユ\\n⁵\\0@²ラᵉ⁵\\0@²ロ\\n゛\\0@²ヲ⁸゛\\0A◜◝²ヲ⁘⁘\\0B⁸²ヲᶜ⁘\\0Bャ²ヲᶜ⁵\\0@²ラᵉ⁵\\0@²ロᶜ(\\0B\\0²ヲᶜ⁵\\0@²ルᶜ⁵\\0@²ᵇロ⁘\\0Lム⁸²\\nム⁘\\0dル¹ᶜ²ヘᶜ⁵•\\0\\0*\\0•\\0\\0▤\\0•\\0\\0ゅ\\0□ᵉ\\0d\\0◀ᵉ◜d\\0⁶ascari⁘ᶠ\\0]ヘ◝ュ⁘¹ᶜ²‖ム\\n\\0q\\n\\0¹ᵉ¹ᵉ²ヲ◀\\n\\0E\\r\\0ル²ル◀\\n\\0A\\n\\0¹ユᶠ\\0Eヘ◝ッ²、ユ-\\0「ᶜ¹ᶠ」\\0x⁸¹\\r¹\\r¹ル⁵\\0Lャ⁵²ロ\\n⁵\\0@²ロ\\n⁵\\0ᶜッ⁶⁘\\0P¹ᶠ¹リ⁘\\0@²ᶜラ\\n\\0H\\n¹リ⁘\\0@²▮ラ⁵\\0\\\\ャ⁵¹\\r²ルᶜ⁵\\0@²ロ\\n⁵\\0ᶜヲ⁶\\n\\0P¹ᶠ²ロᶜ-\\0▮¹\\rᶠ\\0Dレ¹ᵉ ⁙ン\\0ᶜ\\0\\n、¹=\\0⁙ル\\0004\\0⁙ルョ4\\0•\\0\\0웃\\0•\\0\\0テ\\0\t⁘\\0P\\0³⁘\\0P\\0\\n⁘\\0n\\0゜■\\0}\\0²⁘\\0n\\0▮‖\\0L\\0■◀\\0H\\0■\\r\\0🐱\\0▮ᶠ\\0|\\0⁙ヲ\\0n\\0⁘ᶠ²い\\0゜ᶠ\\0し\\0゜ᶠ\\0み\\0◀\t\\0へ\\0゜」\\0チ\\0▮ᶜ\\0ゆ\\0■ᶜュゆ\\0 ッョモ\\0⁷ユ¹レ\\0⁷ユ¹\t¹⁸ユ¹。¹゜」\\0\t¹゜」\\0。¹▮ᶜ\\0⁙¹▮ᶜ\\0\t¹」⁸\\0;¹\\nparabolica⁴\\n\\0⁘ラ¹ᶜ゛\\0E\\r\\0ム²ヘᶜ⁘\\0A\\r\\0²ヘᶜ゛\\0]\\r\\0ル⁶¹ᶠ¹マ⁴⁸モ\\0\\0\\0²モ\\0\\0\\0⁙⁸\\0⁵\\0 ルョT\\0ᶜ\\r\","
      "-- silverstone"
      "\"²ᶠ⁸hamilton³⁘\\0>\\0ヲ⁴¹ᶜ¹ᶜ゛\\0\\0\\n\\0\\\"\\0¹\\r\t⁴」²\\0\\0⁴」²⁘\\0⁴」²(\\0⁷ユ\\0ᵇ\\0³ユ\\0ᵇ\\0▮ユ\\0%\\0⁷ユ\\0/\\0³ユ\\0/\\0ᵇ\\0\\0゜\\0⁵abbey³ᶠ\\0\tᶠ\\0ᶠ゛\\0⁘ロ¹ᵉ\\n\\0⬇️ム◝ᶠ⁴■フ\\0⁘\\0⁷ユ\\0」\\0■ヨ\\0/\\0⁷ユ\\0001\\0⁴farm³ᶠ\\0\\\"\\0¹ᵉ」\\0@¹゛\\n\\0\\0³⁷ユ\\0\\0\\0⁷ユ\\0'\\0³ユ\\0'\\0⁷village²⁘\\0C゛\\0\\0¹ヌ\\n\\0B\\0¹ム\\0⁴loop¹゛\\0³ノ◝\\0\\0⁷aintree²」\\0?ャ◝\\0ロᶠ¹ᶠ¹ᶠ」\\0Cム◝\\0¹゛\\0\\nwellington⁷*\\0j\\0\\n²ᶠ\\r¹゛⁶\\0゛\\0ャ⁵²ᶠ\\r⁴\\0\\0⁶\\0ᵉ\\0ロ\\n゛\\0R\\0¹ᶠ¹ツ%\\0\\0」\\0@¹マᶠ「マ\\0」\\0」⁘\\0。\\0¥ッ\\0゛\\0¥⁶\\0゛\\0³」⁴$\\0「マ\\0%\\0•\\0\\0002\\0◀マ\\0>\\0\tᵉ\\0?\\0³ᵉ\\0?\\0◀マ\\0L\\0◀マ\\0Z\\0「⁘\\0h\\0「⁘\\0q\\0。ᶠ\\0z\\0\\nbrooklands²2\\0⁙マ◝\\0¹ᶜ⁸\\0²\\0⁶▮ᶠ\\0\\r\\0\\n⁘\\0▶\\0²⁘\\0▶\\0▮ᶠ\\0.\\0\\n⁘\\0002\\0²⁘\\0002\\0⁸woodcote⁶」\\0?」\\0\\0ヨ\\n¹ᶠ¹ᵉ⁘\\0▶」\\0\\0ム¹\\r゛\\0\\0⁘\\0\tᶠ\\0⁴F\\0\\0゛\\0\\0「◀ツ\\0ᵇ\\0■フ\\0□\\0◀ツ\\0、\\0▮ツ\\0!\\0⁷ヌ\\0(\\0³ヌ\\0(\\0⁸ヌ\\0A\\0²ヌ\\0A\\0⁸ヌ\\0F\\0²ヌ\\0F\\0、ᶠ\\0P\\0⁸ヌ\\0[\\0²ヌ\\0[\\0、ᶠ\\0🐱\\0「ヌ\\0~\\0■フ\\0●\\0」フ\\0⬅️\\0◀ヌ\\0★\\0◀ヌ\\0え\\0◀ヌ\\0そ\\0◀ヌ\\0は\\0、ᶠ\\0😐\\0□ᶠ\\0ひ\\0⁘ᶠュ♥\\0⁵copse⁵⁘\\0•⁙\\0⁙ᶜ¹ᶜ゛\\0¹¹\\0⁘\\0C¹\\0\\0¹ヌ⁘\\0|ャ⁵²ᶠᵉ¹ᵉ¹ヌ゛\\0p²ᶠᵉ²ᶠᵉ¹ヌ⁸⁸ヌ\\0ᵇ\\0²ヌ\\0ᵇ\\0⁸ヌ\\0」\\0²ヌ\\0」\\0⁸ヌ\\0'\\0²ヌ\\0'\\0□ᶠ\\0003\\0•\\0\\0i\\0⁷maggots³ᶠ\\0³ロ◝\\0」\\0⁵ᵇ\\0ル⁘\\0\\0³⁸ム\\0/\\0²ム\\0/\\0」ラ\\0\\0\\0⁸becketts⁴゛\\0=ヨ◝ヌ゛²ᶠ\\r²ᶠ\\r#\\0Q⁙\\0¹\\r¹ス⁸\\0⁘ヨ¹ᵉᶠ\\0Uヤ◝ン²ᶠᵉ¹ス²「チ\\0>\\0「チ\\0F\\0⁶hangar⁵」\\0\\n\t⁘」\\0.\tャ⁵²ᶠᵉ」\\0Lワ\t²⁘ヌ」\\0bᵉ¹ᵉ¹ム゛\\0\\\"\\0¹ᶜ\\n」ル\\0¥\\0◀\\\"\\0。\\0「」\\0(\\0•\\0\\0003\\0□フ\\0007\\0⁙フ◝8\\0¥ッ\\0P\\0¥⁶\\0P\\0「ᶠ\\0]\\0◀⁘\\0m\\0⁵stowe²<\\0Qᵉ\\0¹ᵉ¹ウ\\n\\0¹ヤ◝⁴⁸フ\\0\\r\\0⁸フ\\0」\\0⁸フ\\0%\\0◀ム\\0007\\0⁴vale⁸ᶠ\\0\\nᵉ\t\\n\\0²ヨᶠ\\0²\\0ᶠ\\0¹ツ◝\\n\\0A\\\"\\0¹ᶠ\\n\\0¹⁵\\0」\\0\\rᵉ\\0ヲ⁴゛\\0⁘ヲ¹ᶜ\\n「ᶠ\\0⁴\\0「ᶠ\\0ᶜ\\0•\\0\\0¥\\0\\nᶠ\\0。\\0、ᶠ\\0(\\0⁷ツ\\0?\\0⁷ツ\\0Y\\0◀ム\\0s\\0³ツ\\0Y\\0「ム\\0{\\0ᶜ²\","
      "-- spa francorchamps"
      "\"²ᵇ³fin⁶゛\\0>\\0ャ⁵²ᶠ\\r¹ᵉ(\\0000¹\\r¹\\r\\n\\0P¹ᶠ¹ロ\\n\\0\\0⁘\\0F\tワ¹ル\\n\\0²ワ\t、\\n\\0゜\\0⁷ル¹#\\0³ル\\0#\\0⁘\\n\\0*\\0、\\n\\0005\\0•\\0\\0?\\0、\\n\\0C\\0□ヨ\\0W\\0「ヨ◜W\\0⁶source⁴゛\\0S゜\\0⁘¹ᵉ¹ム#\\0@¹ヌ゛\\0003²\\0▶¹ᶜ¹ᶜ7\\0□。¹ᶠᶜ「ユ\\0⁶\\0⁷ユ²(\\0⁸ユ²<\\0⁷ユ\\0F\\0³ユ\\0F\\0⁘\\r\\0<\\0³ᶠ⁴R\\0⁘\\r\\0H\\0³ᶠ⁴f\\0□ᶜ\\0😐\\0◀ム\\0g\\0 ⁷ョn\\0⁴raid⁷\\n\\0エル◝マヨᶜ¹」\\n\\0タ\t\\0シ⁘¹ᵉ¹」」\\0ょ⁸\\0\\0ᶜ¹」⁸\\0わヨ◝ッ¹ᵉ2\\0Rᵇ¹ᶜ²⁘ム⁘\\0X⁷¹ᶠ²ᶠレᶠ\\0ニ⁸\\0¹\\r²ᵇレ⁵³フ²「\\0「フ◜-\\0□フ\\0-\\0⁙ᶠ¹A\\0⁙ᶠ¹H\\0³kem⁴U\\0B³¹⁘#\\0Rャ²ᶠ\\r¹ᶜ(\\0@¹ᶜ」\\0\\0ᶜ⁷ラ\\0⁵\\0⁷ラ\\0」\\0⁷ラ\\0-\\0⁷ラ\\0A\\0゜ᶜ\\0<\\0□ᶜ\\0@\\0 ュョT\\0⁙\t\\0S\\0 ⁶ョT\\0▮ᵉ\\0R\\0■ᵉャR\\0 ュョて\\0⁶combes⁷⁘\\0m「\\0ヌ⁘¹ᵉ¹ツ⁘\\0}フ◝ッ⁶¹ᵉ¹ᶜ²ナ⁘⁸\\0`¹\\r¹\t⁘\\0A⁘\\0¹\\n\\n\\0A「\\0¹\\n(\\0\\\"\\n¹ᵉ⁘\\0r‖²ᶠ\\r¹\\r¹ᶠ\\r」ス\\0」\\0⁙ヨ\\0007\\0◀ヨ\\0:\\0「ヨ\\0A\\0⁷ヤ¹F\\0 ュョz\\0□ム\\0∧\\0□ム◜∧\\0▮ム\\0_\\0■ムャ_\\0゜ᶠ\\0n\\0▮⁘\\0k\\0■⁘ャk\\0⁴brux\t<\\0Y「\\0\\n¹ᵉ¹フ#\\0tヌ¹ᶠ¹ᶠ¹ᶠ」\\0eホ◝ヲ¹ᵉ¹ᶠA\\0p²ᶠ\\r¹\\r²ヨᶠᶠ\\0A³\\0²ヨᶠ⁵\\0Lャ⁵²ヨᶠ⁵\\0@²ヨᶠ⁵\\0Lヲ⁷¹ヨ#\\0@¹ヨ⁴¥⁷\\0d\\0¥⁷\\0a\\0•\\0\\0エ\\0\tᶠ²ヒ\\0⁴pouh⁷」\\0yマ◝\\n¹\\r¹ᵉ¹ム⁸\\0iワ◝▮¹ᶜ¹ム」\\0iラ◝⁘¹ᵉ²゛ム゛\\0`¹ᶜ²゛ム⁘\\0`¹ᵉ¹ヨ⁘\\0~\tャ⁵¹ᵉ¹ᵉ¹ヨ⁵\\0@¹ヨᵇ\\n⁘²⁴\\0「◀\\0ᶠ\\0\\n」\\0‖\\0「◀\\0!\\0⁙◀\\0-\\0「」\\0R\\0「」\\0J\\0\\n゛¹Z\\0\\n⁘¹s\\0□゛\\0g\\0•\\0\\0🐱\\0⁶campus⁷⁘\\0}■\\0ヨ⁸¹ᶜ¹\\r¹ヌᶠ\\0Y■\\0ᶠ¹ᵉ¹ヌ⁶\\0@²ム⁘」\\0mモ◝ヲ⁸¹ᵉ¹゛⁘\\0ᶜャ⁵⁵\\0\\0⁘\\0,ッ⁸¹ᶠ⁵•\\0\\0S\\0⁙⁘\\0B\\0◀⁘\\0H\\0¥ロ◝k\\0⁸フ\\0~\\0⁴stav⁶」\\0E‖\\0ル¹ス⁘\\0\\0」\\0A‖\\0¹ヌ(\\0A²\\0¹ヌ゛\\0A¹\\0²フᶠ(\\0A²\\0²ムᶠ⁷「フ\\0A\\0□フ\\0G\\0「フ◜G\\0□ᵉ\\0U\\0◀ᵉ◜U\\0▮ᶜ\\0P\\0■▮\\0O\\0⁴blanᵇ゛\\0@²ムᶠ⁵\\0Lャ⁵²ヨᶠ⁵\\0@²ヨᶠ⁵\\0/ロ◝\\0ヲ⁸¹ᵉ゛\\0Aル◝²ム⁘゛\\0@²」ム⁘\\0Aワ◝²」ム⁸\\0Aマ◝²フ⁘2\\0H▮²ム」(\\0I⁶\\0゛¹フ」\\0▮¹ᶜ⁵•\\0\\0%\\0¥ッ\\0に\\0¥ッ\\0ほ\\0¥⁶\\0ほ\\0³マ³ノ\\0⁴chic²゛\\0\t¥\\0⁷゛\\0-ヌ◝ャ⁵²ᶠᶜ¹⁘ス\\0ᶠ\\0ᶜ²\","
      "-- suzuka"
      "\"²⁵⁵start⁸\\n\\0<ロ⁴¹ᶠ¹\\r<\\0,ロ⁴¹\\r⁘\\0⁸ᶠ⁘\\0 ²ᶠ\\r#\\0G\\n\\0\\nヨ¹フ#\\0Qᵉ\\0¹ᵉ¹ツᶠ\\0⁴マ⁘\\0dヨ²ᶠᵉ¹ぬ■ᵇ\\0\\0⁘\\0、ᶠ\\0\\0\\0、ᶠ\\0\\n\\0、ᶠ\\0⁘\\0、ᶠ\\0゛\\0、ᶠ\\0(\\0、ᶠ\\0002\\0⁸ム\\0\\0\\0⁷ム\\0‖\\0•\\0\\0A\\0□ムャ(\\0゜⁸\\0H\\0⁷フ\\0∧\\0 ヲョU\\0、゛\\0キ\\0⁷ヌ\\0ね\\0¥\\n\\0h\\0⁴scrv⁸」\\0ᶠラ◝¹ャ゛゛\\0ᵇ\\r\\0⁘ᶠ⁘\\0ᶜヨ⁵」\\0⁵リ◝ヲ*\\0Sᵉ\\0⁙²ᶠᵉ¹ツ\\n\\0Cュ◝ヲ¹ろ」\\0sユ◝\\0²ᶠ\\r¹ᶜ¹((\\0Aリ◝¹<ᵇ。゛\\0\\n\\0「フ\\0.\\0⁸ヌ\\0}\\0」⁘\\0キ\\0」\\n\\0ゆ\\0◀7\\0 \\0⁸ヌ\\0007\\0「2\\0^\\0⁘⁘\\0_\\0ᶜムュK\\0⁷ム\\0⬅️\\0⁶degner\t」\\0hᶠ¹\\r¹ヨ\\n\\0クᵇ\\0\t²ᶠᵉ¹ヨ⁘\\0@¹ヨ」\\0]▮\\0ャ⁵¹ᵉ¹フ\\n\\0\\0゛\\0□ロ¹\\r⁘\\0p²ᶠ\\r²ᶠ\\r¹ムᶠ\\0s\\r\\0\\0¹ᵉ¹\\r¹ウ□\\0`¹ᶜ¹ᶠᵇ゜ウ\\0-\\0•\\0\\0U\\0「ヨ\\0F\\0「ロ\\0d\\0「\\n\\0d\\0□\\n\\0]\\0\\nᶠ\\0s\\0 ョョ☉\\0⁸ス\\0か\\0!を◝U\\0!:◝U\\0²hp▮<\\0Kナ◝\\0ᶜ²F-⁘\\0 ¹\\r」\\0y⁷\\0\\n²ᶠᵉ²ᶠ\\r²ムツ\\n\\0Kᵇ\\0ᶜ⁶²ムツ⁘\\0³⁸\\0ュ⁘\\0M⁸\\0リ⁘¹ム」\\0⁷\t\\0ワヌ⁘\\0b\\0¹ᶜ¹゛゛\\0aモ◝²ᶠᶜ¹゛」\\0¹ル◝ᶠ\\0Gム◝⁘ロ¹゛゛\\0O◝◝\\0ン⁷¹゛(\\0○◝◝ワャ⁵¹\\r¹\\r¹ᶠ2\\0B\\0²ᶠ▶」\\0`²ᶠ\\r¹ワ」\\0▮²ᶠ\\rᵉ\t□\\0=\\0•\\0\\0○\\0 ョョP\\0「」\\0シ\\0\t#\\0マ\\0◀\\n\\0/¹•\\0\\0Z¹「⁸\\0d¹•\\0\\0🐱¹¥ヲ\\0j¹□\\n\\0け¹□\\n◜け¹」ル\\0の¹ ³ョね¹³cas⁶⁘\\0=ラ◝ヲᶜ²ᶠᵉ²ᶠᵉ゛\\0¹ワ◝゛\\0,ッ⁴¹ᶜ⁘\\0⁵‖\\0ム⁘\\0\\rミ◝ヲ⁘#\\0-\\r\\0ロ⁴¹\\r⁶•◝\\0O\\0」□\\0'\\0」⁘\\0:\\0⁸ヌ\\0V\\0⁸ヌ\\0c\\0⁷ム\\0█\\0\\r²\""
      "}"
      "")
    (p8-section gfx
      "00000000cccccccc00000000000077770000000000000000000000000000000099cccccc81111111111111888811111111111118ccccc677d1dcc777d1dcc677"
      "0000000077777777000000077777776700770000000000000000000000000000c67ccccc81111111111118111181111111111118ccc11d77d1117777d111d677"
      "00700700777777770007677766777777777707000077000000000000000000005577755c81111111111181000018111111111118ccc11d76111177761111d676"
      "0007700077777777077777667777777766777777777777700000000000000000559995598ccccccccccc81000018ccccccccccc8ccc11d5111116d5111116656"
      "0007700077777777666677777777766766666677066776670000000000000000cccccccc81111111111811000011811111111118cc1dd111d5111111d51d1117"
      "0070070077777777000776676667666766770000007660000000000000000000cccccccc81111111111811000011811111111118cc7761116776111d67711117"
      "0000000077777777000000007670007000000000000000000000000006688668cccccccc8ccccccccc811111111118ccccccccc8cc76d1116777111d6771111c"
      "00000000cccccccc000000000000000000000000000000006688668866886688cccccccc8ccccccccc811111111118ccccccccc8cc5115d6115d15d6115155dc"
      "ddddddddebebbbee0000b0000000000b200000000000000007777770cccccccccccccccc8ccccccccc8111bbbb1118ccccccccc8cc111777111177771111d77c"
      "ddddddddebbbebbe0000b0000000000be00000000000000005577550cccccccccccccccc8ccccccccc811eb77be118ccccccccc8cd111777111177771d11d77c"
      "ddddddddbeee2eee000be200000000eee20000000000000000077000cccccccccccccccc8cccccccc811ebbbbbbe118cccccccc8cd11d776111177761d11d77c"
      "ddddddddbbbee2ee00eb20000000000ee00000000777700000077000cccccccccccccccc8cccccccc81191111119118cccccccc8c6dd11516d516d51665ddd5c"
      "ddddddddbeeeb2e2000bee0000000ebb202000000066000000077000cccccccccccccccc8cccccccc81177777777118cccccccc8c776111177761111777611cc"
      "ddddddddbee2eee20e0eb220000000ebe0e000000000000000055000ccc2222222222ccc8cc888cc8167766666677618cc888cc8677711117777111d777d11cc"
      "ddddddddebeee2220bbee0000000b0beee2200000000000000000000cc222222222222cc8ccaaacc8ddd66777766ddd8ccaaacc877cccc11777d111d776d11cc"
      "ddddddddee22ee2ebbee2e2000000eeee20000000000000000000000cc222222222222cc8cccccac1dd8888888888dd1caccccc8cccccccccc6d11cccc6111cc"
      "55555555ee2ebebbbbbeeee20000b0b0bbb0000000000000ccccccc1111111111111228888888888888ff888aaaaaaaaaaaa888888221111111111111ccccccc"
      "55555555e22bbbbbbbbbbb22000bbbb0bb00bb0000000000cccccc121111111111211aaaaaaaa88888fff8888aaaaaaa11aaaaa1aaa112111111111121cccccc"
      "55555555ebebbeebbebebeee0b00beebbe0eb00000000000cccccc152122121222511a1111111a88a8fff8888aaaaaaa1aaa111111a115222121221251cccccc"
      "55555555bbbbbbbeeebbeebbbbb00bbeeebbeee000000000cccccc15225522525521111111111aa8a8fff8888aaaaaaa1aa11111111112552522552251cccccc"
      "55555555bbbbebbbebbeeeee0bbbebbbebbe00ee00000000ccccc1212222122225111111111111a8a8fff8888aaaaaaa1aa111111111115222212222121ccccc"
      "55555555ebbbbbbeeeeee2e200bbbbbeeeeee2e200000000ccccc1211111111115111111dd111118a8ff88888aaaaaaa1aa111111111115111111111121ccccc"
      "55555555bbbebeeee2e22ee2b0bebeeee2e22e0086688660ccccc111111111111211dd1111dd111aa8888aaaa11aaaaaaa11111111dd112111111111111ccccc"
      "55555555bbbbebee22eeee22bbbbebee22eee02288668866ccccc11111111111111151dd1111dd1aa88aa8888aa11aaaa1111111dd15111111111111111ccccc"
      "ccccccccbeebe2e22beeeee2beebe2e22beeeee200000000cccc88111111111111115111dd111111a8a888888aaaa1aa111111dd11151111111111111188cccc"
      "ccccccccbbbeeee2bbee222ebbbeeee2bbee200000000000ccccfa11111111111111511111dd11ddaa8888888aaaaa1add11dd11111511111111111111afcccc"
      "ccccccccebeee2eebeee222eebeee2eebeee202000000000ccccfa1111111111111151111111dd11aa8888888aaaaaaa11dd1111111511111111111111afcccc"
      "ccccccccebe22ebeeee22e220be22ebeeee22e2200000000cccf8aaaaaaaaaaa1111511111dd111a8a8888888aaaaaa1a111dd1111151111aaaaaaaaaaa8fccc"
      "ccccccccebebeeeeee22e22e0bebeeeeee22e22000000000ccc8aaaaaaaaaaaaaaaaaaaaaaaaaaaaf8a88888aaaaaaa1aaaaaaaaaaaaaaaaaaaaaaaaaaaa8ccc"
      "ccccccccb2e2eee2eeee2e2e0e0eee02eee0202000000000ccc8a8888888888888888888888888888faa8888aaaaaa1a888888888888888888888888888a8ccc"
      "ccccccccee22e222e2e2bbe2000e2002e2e0000000000000ccc8ac111111111111111111111111111aaaa88aaaaaa1aa11111111111111111111111111ca8ccc"
      "ccccccccee2eee22222eee2e0000ee02202e000088668866cccaacc111111111111111ccccccccc111aaaaaaaaaaa1111ccccccccc111111111111111ccaaccc"
      "6d6d6d6d0000000066666666666666666666666dcccccccccccccccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "d6d6d6d6000000006555555555555555555555d5cccccccccccccccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "6d6d6d6d00000000650000000000000000000065c55c55cc55ccc55c000000000000000000000000000000000000000000000000000000000000000000000000"
      "d6d6d6d6000000006500000000000000000000655cc5cc5ccc5c5ccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd00000000650000000000000000000065ccccccccccc5cccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "d6d6d6d688888888650000000000000000000065cccccccccccccccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd88888888650000000000000000000065cccccccccccccccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "dd6ddd6d88888888650000000000000000000065cccccccccccccccc000000000000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd00000000650000000000000000000065cc1111111cccc111111ccccc0000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd00000000650000000000000000000065cc16616611111161161111cc0000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd00000000650000000000000000000065cc16161616661161111661cc0000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd00000000650000000000000000000065cc16161616161666116111cc0000000000000000000000000000000000000000000000000000000000000000"
      "d5ddd5dd00000000650000000000000000000065cc16161616161161111161cc0000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd66666666650000000000000000000065cc16161616661161c16611cc0000000000000000000000000000000000000000000000000000000000000000"
      "5d5d5d5d66666666650000000000000000000065cc11111111111111c1111ccc0000000000000000000000000000000000000000000000000000000000000000"
      "dddddddd66666666650000000000000000000065cccccccccccccccccccccccc0000000000000000000000000000000000000000000000000000000000000000"
      "d5d5d5d5cc56d5cc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "5d5d5d5dcc56d5cc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "d5d5d5d5cc56d5cc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "5d5d5d5dcc56d5cc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555cccccccc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "5d5d5d5dcccccccc6500000000000000000000650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555cccccccc6d66666666666666666666650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55d555d5ccccccccd555555555555555555555550000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555000000000017100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555000000000016710000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "51555155000000000016671000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "55555555000000000016d10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "1515151500000000001d100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "51515151888866660001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "11111111888866660000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000cccccc0000000000000000"
      "cccccccccccc0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "cccccccccc007777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "ccccccccc0777777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "ccccccc007777777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "cccccc0077777777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "cccccc0777777777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "ccccc07777777777777770cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770cccccc0000000000000000"
      "ccccc09999999990000000cccccccccccc0000000cccccc0000000000ccccccccccccc000000000ccccccccccccc00000009999990cccccc0000000000000000"
      "cccc099999999008888880ccccccccccc09999990ccccc0099999999900cccccccccc00999999990cccccccccc0099999009999990cccccc0000000000000000"
      "cccc099999990080000000cccccccccc099999990ccc0099999999999900cccccccc0999999999990cccccccc09999999009999990cccccc0000000000000000"
      "cccc09999999080c000000000cccccc0999999990ccc09999999999999900cccccc099999999999990cccccc099999999009999990cccccc0000000000000000"
      "cccc0999999900cc0999999900cccc09999999990cc099999999999999990ccccc00999999999999990cccc0999999999009999990cccccc0000000000000000"
      "cccc099999990ccc0999999990cccc09999999990c09999999999999999990cccc09999999999999990ccc00999999999009999990cccccc0000000000000000"
      "cccc099999990ccc09999999990ccc09999999900c09999999999999999990cccc09999999999999990ccc09999999999009999990cccccc0000000000000000"
      "cccc099999990ccc09999999990ccc09999990000c09999990000099999990cccc09999990009999990ccc09999990000009999990cccccc0000000000000000"
      "cccc099999990ccc09999999990ccc09999990880c09999990888809999990ccc099999908809999990ccc09999990888009999990cccccc0000000000000000"
      "cccc0999999900cc00099999990cc09999999000c099999990000009999990ccc099999900009999990cc099999990000009999990cccccc0000000000000000"
      "cccc08888888800c08808888880cc088888800ccc008888880cccc08888880ccc08888880cc08888880cc008888880cccc08888880cccccc0000000000000000"
      "cccc00888888880000008888880cc088888800ccc008888880000008888880ccc08888880cc08888880cc008888880000008888880cccccc0000000000000000"
      "cccc00888888888888888888880cc08888880ccccc08888888888008888880ccc08888880cc08888880ccc08888888888888888880cccccc0000000000000000"
      "ccccc0088888888888888888880cc08888880ccccc08888888888008888880ccc08888880cc08888880ccc08888888888888888800cccccc0000000000000000"
      "ccccc0808888888888888888800cc08888880ccccc00888888888008888880ccc08888880cc08888880ccc0088888888888888880ccccccc0000000000000000"
      "cccccc000444444444444444000cc04444440ccccc08044444444004444440ccc04444440cc04444440ccc0804444444444444400ccccccc0000000000000000"
      "ccccccc0804444444444444000ccc04444440cccccc0004444444004444440ccc04444440cc04444440cccc000444444444444000ccccccc0000000000000000"
      "ccccccc0080044444444440080ccc04444440ccccccc080044444004444440ccc04444440cc04444440ccccc0800444444440080cccccccc0000000000000000"
      "ccccccccc0880000000000880cccc00000000cccccccc08000000000000000ccc00000000cc00000000cccccc080000000000800cccccccc0000000000000000"
      "cccccccccc00888888888800ccccc08888880ccccccccc0888888008888880ccc08888880cc08888880ccccccc088888888880cccccccccc0000000000000000"
      "cccccccccccc0000000000ccccccc00000000cccccccccc000000000000000ccc00000000cc00000000cccccccc0000000000ccccccccccc0000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccc00000ccccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "ccccccccccccccccccccccccccccccccccccccccccc0777770cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "ccccccccccccc000000000ccccccccccccccccccccc0777770cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "ccccccccccc0077777777700cccccccccccccccccc07777770cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "cccccccccc007777777777700ccccccccccccccccc00777770cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "ccccccccc00777777777777700cccccccccccccccc00777770cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "ccccccccc07777777777777770ccccccccccccccccc0000000cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "cccccccc0999999999999999990cccccccccccccccc0888880cccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "cccccccc0999999999999999990ccccccccccccccc00000000ccc00000000cc00000000c00000000000000000000000000000000000000000000000000000000"
      "cccccccc0999999000099999990ccccccc0000000c09999990ccc09999990cc09999990c00000000000000000000000000000000000000000000000000000000"
      "cccccccc0999999088099999990cccccc09999990c09999990ccc09999990cc09999990c00000000000000000000000000000000000000000000000000000000"
      "cccccccc0999990000099999990ccccc099999990c09999990ccc09999990cc09999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990000999999990cccc0999999990c09999990ccc09999990cc09999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990c09999999990ccc09999999990c09999990ccc00999990cc09999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990c09999999990ccc09999999990c09999990ccc009999990009999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990c09999999900ccc09999999900c09999990cccc09999999999999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990c09999999000ccc09999990000c09999990cccc00999999999999990c00000000000000000000000000000000000000000000000000000000"
      "ccccccc09999990c0999999000cccc09999990880c09999990cccc00099999999999000c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880c0000000800ccc08888888000cc08888880ccccc0088888888888000c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880c088888800cccc088888800cccc08888880cccc00888888088888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880c0000000cccccc088888800cccc08888880cccc08888880008888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880cccccccccccccc08888880ccccc08888880cccc08888880808888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880cccccccccccccc08888880ccccc08888880cccc08888808008888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880cccccccccccccc08888880ccccc08888880ccc088888800c08888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc04444440cccccccccccccc04444440ccccc04444440ccc04444440cc04444440c00000000000000000000000000000000000000000000000000000000"
      "ccccccc04444440cccccccccccccc04444440ccccc04444440ccc04444440cc04444440c00000000000000000000000000000000000000000000000000000000"
      "ccccccc04444440cccccccccccccc04444440ccccc04444440ccc04444440cc04444440c00000000000000000000000000000000000000000000000000000000"
      "ccccccc00000000cccccccccccccc00000000ccccc00000000ccc00000000cc00000000c00000000000000000000000000000000000000000000000000000000"
      "ccccccc08888880cccccccccccccc08888880ccccc08888880ccc08888880cc08888880c00000000000000000000000000000000000000000000000000000000"
      "ccccccc00000000cccccccccccccc00000000ccccc00000000ccc00000000cc00000000c00000000000000000000000000000000000000000000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000000000000000000000000000000000000000000000000000")
    (p8-section label
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc7777ccccccc7777cccccccccccccc7777cccc777cccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc77777ccccc77777cccccccccccccc7777cccc777cccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc77777ccccc77777cccccccccccccc7777cccc777cccccccccccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc777777ccc777777cccc77777cccc77777777c777ccc77777cccccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc777777ccc777777ccc7777777ccc77777777c777cc77777777cccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc7777577c7757777cc777555777cc57777555c555cc77755577cccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc7777c77c77c7777cc777ccc777ccc7777ccccccccc77777c55cccccccccccccccc"
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc7777c57775c7777c7777ccc7777cc7777ccccccccc7777777ccc00000000cccccc"
      "cccccccccccccccccccccccc00000000000ccccccccccccccccccccccccccc7777cc777cc7777c5777ccc7775cc7777ccccccccc5555777ccc07777770cccccc"
      "cccccccccccccccccccccc0077777777770ccccccccccccccccccccccccccc7777cc575cc7777cc777ccc777ccc5777cccccccc7cccc777ccc07777770cccccc"
      "ccccccccccccccccccccc07777777777700c77cccccccccccccccccccccccc7777ccc5ccc7777cc577777775cccc777777ccccc77777777cc077777700cccccc"
      "ccccccccccccccccccc0077777777777700777777ccccccccccccccccccccc7777ccccccc7777ccc5777775ccccc577777ccccc55777775cc077777700cccccc"
      "cccccccccccccccccc007777777777777006677667cccccccccccccccccccc5555ccccccc5555cccc55555ccccccc55555ccccccc55555ccc077777700cccccc"
      "ccccccccccccccccc07777777777777770cc766cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc07777770ccccccc"
      "cccccccccccccccc007777777777777770ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000007777770ccccccc"
      "cccccccccccccccc077777777700000000ccccccccccc0000000ccccccc000000000ccccccccccccccc00000000ccccccccccccc00000000077777700ccccccc"
      "ccccccccccccccc0aaaaaaaa0088888880ccccccccc00aaaaaa0ccccc00aaaaaaaaa00ccccccccccc00aaaaaaaa00cccccccccc00aaaaa000aaaaaa00cjccccc"
      "ccccccccccccccc0aaaaaaa08888888880cccccccc00aaaaaaa0ccc00aaaaaaaaaaaaa0cccccccc00aaaaaaaaaaa00ccccccc00aaaaaaa000aaaaaa00jjjcccc"
      "cccccccccccccc0aaaaaaa00880000000cccccccc00aaaaaaaa0cc00aaaaaaaaaaaaaaa0cccccc00aaaaaaaaaaaaa0cccccc00aaaaaaaa000aaaaaa0jjjjjjjc"
      "cccccccccccccc0aaaaaaa0800c00000000ccccc00aaaaaaaaa000aaaaaaaaaaaaaaaaa0cccccc0aaaaaaaaaaaaaaa0cccc0aaaaaaaaaa000aaaaaa0j3j1jj1j"
      "ccccccccccccc0aaaaaaa080cc0aaaaaaa0ccccc0aaaaaaaaa0000aaaaaaaaaaaaaaaaa0ccccc0aaaaaaaaaaaaaaaa0ccc00aaaaaaaaa000aaaaaa003jjjj11j"
      "jcccccccccccc0aaaaaaa000cc0aaaaaaaa0ccc00aaaaaaaa0000aaaaaaaaaaaaaaaaaaa0ccc00aaaaaaaaaaaaaaaa0ccc0aaaaaaaaa0000aaaaaa00j3jjjj11"
      "jcccccccccccc0999999900ccc0999999990ccc0999999900000999999900000099999990ccc0999999000009999990cc09999999000000099999900jjjjj1jj"
      "jjccccccccccc099999990cccc0999999990ccc0999999088800999999008888099999990ccc0999999088809999990cc0999999088880009999990jrr3jrrrr"
      "jjccccccccccc099999990cccc099999999033r0999999088000999999088888099999990ccc0999999088809999990cc0999999088800c09999990rjrrrrr3r"
      "jjrjccccccccc0999999900j3r00999999903r09999990800009999990800000099999900cc09999990000099999900c09999999000000099999900rrr3rrr33"
      "jj3jjcccccrcr0999999990ar30409999990r3099999900ccc0999999900j1j1099999900cc099999900jj099999900j09999999033j30099999900r33rr33j3"
      "j3rr3jjjcccrr088888888800000088888803j088888800ccc08888888000000088888800cc08888880033088888800308888888000000888888800r33r3jj3r"
      "3r333jjjjjrrj008888888888888888888003r08888880cccc0888888888880008888880jjj08888880rrj088888803j0888888888888888888800j3jr33jjrr"
      "3rj3jjjjjjjj300888888888888888888800jr08888880cccc0088888888880008888880jjj08888880j3j08888880rr0088888888888888888000jj3j33jjr3"
      "r333rrjjjjj3308088888888888888888080j0888888006ccc0088888888800088888800jj088888800jr0888888003r0088888888888888888080jj3jjj3j3j"
      "33r3r3rjjj3rr3000888888888888888080r3088888800cccc0008888888800088888800jj088888800r60888888003j080888888888888880080r3r3r3jrr66"
      "r3rr3333jrr3jr08004444444444444088033044444400cccjj000444444400044444400jj0444444006304444440033r00044444444444400800rrr3366rr3r"
      "jrrjjr33j333jr30800444444444400880r6304444440674444080044444400044444404440444444046r04444440r3j30800444444444008880r563r3rr366r"
      "333666jj3jj33rr008800000000008880r6560000000044444400880000440000000000444000000004630000000033333088000000000888003353366rrr333"
      "6663j3jj333j33j500888888888888803636408888880444444400888880000088888804440888888046608888880r3jj600888888888888006rj5j333r66633"
      "3r33j3rrr43jr665600888888888800j636460888888044444777008888880008888880444088888804460888888033rr360088888888800r3r36563jj3333r3"
      "rrr33rr36666666566600000000003j6656640000000044444444450000880000000000444000000004470000000063jrrr66000000000rr33rr353j366633r3"
      "3666666666jjrr3566666j3r3r5363633746644444444444444445165550006555555555444444444444447646r737j63j366665j333666666333533r3376j33"
      "3673j367r3373335r3633j3j63566j733444464444444444444440555555555555555055444444444444444464656533637656j5rr7337rrr7333566rr73r367"
      "rr3676r3663366r56r56735733565r56667444444444444444445055555555555555555544000004444444444464446646636365673673r663r6753366r3j366"
      "7rr656rr637jjr653j735375j75476488888866888888444444505555555555555555055407777088886688888874444647636r533363r73637rr5r73rr676rr"
      "6663j366j36j73357j567r3646546448888a956688000000000055555555555555555555077777708a9566a888847664445760000r36r66jr6633566r33666rr"
      "33j36rjr663j6475447444746654444888894999007777777770055555555555555555550777777085499998888446476466307703j763563j3665336633r366"
      "77633j76344644657646644676564448888588007777777777777055555555555555555507777700808888088884444444576077036588888888888888888888"
      "66574644664446454474646464444444444440077777777777777705556666666666666507777080444444444444444444000077000088888888888888888888"
      "777777777777775d4646664444444444444400777777777777777770775575555555555600000880444444444444444444077777777088888888888888888886"
      "d77777777777775d444444444444444444400777777777777777777055555555555555550888880644444444444444444407777777708888888888885aaa4996"
      "d44676444344445d4444444777777174444077777777777777777770555555555550000000000044664000000044440000000077000088888888888805994495"
      "d44646733333335d0047444777777110004077777700000077777770557555000000000777777044440777777044407777088077088088888888888805aaa44a"
      "d00444433333335d5001000144444000050777777088888077777770555500777777000777777065440777777044407777000077000088888888888805599949"
      "d50044333333335d0000055504440000510aaaaaa0888800aaaaaaa055500aaaaaaa000aaaaaa055650aaaaaa04440aaaaaa0000044488888888888855599949"
      "d5504433333333500000551503350000100aaaaaa00000aaaaaaaaa05500aaaaaaaa000aaaaaa005550aaaaaa04440aaaaaa0088044488888888888885544449"
      "d0157333333333500000510050330000100aaaaaa0550aaaaaaaaa00500aaaaaaaaa000aaaaaa055550aaaaaa06640aaaaaa0000044488888888888885500049"
      "3300100000033330000051605033000050aaaaaa0050aaaaaaaaaa0050aaaaaaaaa000aaaaaa0055550aaaaaa0650aaaaaa00444444488888888888885500544"
      "3000500005003330000050105033000050aaaaaa0050aaaaaaaaa08000aaaaaaaa0000aaaaaa0055550aaaaaa0000aaaaaa00444444444444444444444444444"
      "00051111110003j0000051050j555000109999990050999999990005099999990000009999990055550999999999999999000444444444444444444444444444"
      "00005111150003300000555505555555709999990550999999900805099999908880009999990555550099999999999990005555554444444444444444444444"
      "00000000000000jj0000050055555557509999990550999990088055099999908800009999990555550009999999999900800055555544444444444444444444"
      "55555555555555555555555555555575099999900500000000880050999999080000099999900555550999999999999990005555555566554444444444444444"
      "55555555555555555555555555555575099999900508888888800550999999005550099999900555509999999999999999055000550000055555555444444444"
      "55555555555555555555555555555755088888800508888880055550888888005555088888800555088888800000888888065555555555005555555555544444"
      "55550005555555555555555555557555088888805500000000555550888888005555088888806655088888808880888888056555555555555555666555555444"
      "55555555555555555555555555575555088888805555555555555550888888055555088888805555088888808880888888055655555555555555110000055555"
      "55555555555555555555555555755550888888005555555555555508888880055550888888005550888888000008888880055565555555555555555555500005"
      "55555555555555555555555555655550444444005555555555555504444440055550444444005550444444005504444440055565555555555555000055500005"
      "55555555555555555555555556555550444444005555555555555504444440055550444444005550444444005504444440055556555555555555555000055555"
      "55555555555555555555555565555550444444055555555555555504444440555550444444055550444444055504444440555555655555555555555555555555"
      "55555555555555555555555565555550000000055555555555555500000000555550000000055550000000055500000000555555655555555555555555555555"
      "55555555555555555555555655555550888888055555555555555508888880555550888888055550888888055508888880555555565555555555555555555555"
      "55555555555555555555555655555550888888055550000555555508888880555550888888055550888888055508888880555555565555555555555555555500"
      "55555555555555555555556555555550000000055555555555555500000000555550000000055550000000055500000000555555556555555555555555555555"
      "55555555555555500555556555555555555555555555555555555555555555555555555555555555555555555555555555555555556555550055555555555555"
      "00000000000000000155556555555555555555555555555555555555555555555555555555555555555555555555555555555555556500010000000000000000"
      "00000000000000000015565555555555555555555555555555555555555555555555555555555555555555555555555555555555555655100000000000000000"
      "55555555555550000005565555555555555577777777777777777777777777777777777777777777777777777777555555555555555655000000555555555555"
      "11111111111100000005565555555555555776777677767776777677767776777677767776777677767776777677755555555555555651000000011111111111"
      "00000000000000000000655555555555555775555555555555557777555555555555555555555555555555555557755555555555555560000000000000000000"
      "000000000000000000006555555555555c676508800888080005676750000000000000000000000000000000005767c555555555555560000000000000000000"
      "000000000000000000006555555555ccc7767500800808080005767650r0r0r0r0r0r0r0r0909090909080800056767ccc555555555560000000000000000000"
      "0000000000000006100165555555cc7776666500800888088805666650r0r0r0r0r0r0r0r0909090909080800056666777cc5555555161001610000000000000"
      "11111111110000056006155555cc777776666500800008080805676650r0r0r0r0r0r0r0r090909090908080005666677777cc55555116006560000111111111"
      "555555555500000561061555cc7777776666650888000808880566665000000000000000000000000000000000566666777777cc555106016560000555555555"
      "1111111111000065561615cc777777cc6666655555555555555566665555555555555555555555555555555555566666cc777777cc5106165550000111111111"
      "11111111110000655616cc777777cccs6666666666666666666666666666666666666666666666666666666666666666sccc777777cc16165550000111111111"
      "000000000000006556cc777777ccccsc6666666666666666666666666555555555565556666666666666666666666666cscccc777777cc165550000000000000"
      "0000000000000065cc777777cccscscs6566656665666566656665655555885555555555556665666566656665666566scscsccc777777cc5550000000000000"
      "00000000000001cc777777ccccscssss6666666666666666666555555000880000050005555566666666666666666666sssscscccc777777cc50000000000000"
      "000000000001cc777777cccscscsssss5656565656565656555555500000880000000000055555565656565656565656ssssscscsccc777777cc100000000000"
      "1111111111cc777777ccccscssssssss6565656565656565555500000000088000000000000005556565656565656565sssssssscscccc777777cc1011111111"
      "55555555cc777777cccscscsssssssss5555555555555555550000000000088000000000000000555555555555555555ssssssssscscsccc777777cc15555555"
      "111111cc777777ccccscsssssssssjs566666666666665500000000000000880000000000000000055556666666666665sjssssssssscscccc777777cc111111"
      "1111cc777777cccscscsssssssssss55555555555555550000000000005555555550055000000000005555555555555555ssssssssssscscsccc777777cc1111"
      "01cc777777ccccscsssssssssssjs5555555555555555500000000000500000100055005500000000005555555555555555sjssssssssssscscccc777777cc10"
      "cc777777cccscscsssssssssssss555555555555555500000000055550010017100010000550000000005555555555555555ssssssssssssscscsccc777777cc"
      "777777ccccscsssssssssssssjs55555555555555550000000055550001710010001710005550000000005555555555555555sjssssssssssssscscccc777777"
      "7777cccscscsssssssssssssss5555555555555555000000055555000001000000001000005555000000005555555555555555ssssssssssssssscscsccc7777"
      "77ccccscsssssssssssssssss555555555555555500000005555500010000000000000010005555000000005555555555555555ssssssssssssssssscscccc77"
      "cccscscsssssssssssssssss55555555555555550000005555555001710000000000001710055555500000055555555555555555ssssssssssssssssscscsccc"
      "ccscsssssssssssssssssjs5550000555555555000000055555500001000000000000001000055555500000055555555555555555sjssssssssssssssssscscc"
      "cscsssssssssssssssssss555055550555555500000005555555000000000000000000000000555555500000005555550000001155ssssssssssssssssssscsc"
      "sssssssssssssssssssjs55505373350555555000000055555550001000000000000000001005555555500000055555500055676555sjsssssssssssssssssss"
      "ssssssssssssssssssss5555053333505555550000005555555500171000000099990000171055555550500000555555000556765555ssssssssssssssssssss"
      "sssssssssssssssssjs5555505r33r5055055000000500555555000100000000000099990100555555005000000550550000001155555sjsssssssssssssssss"
      "ssssssssssssssssss555555053rr350500500000005000555550000000000000000000000005555500175000005550555555555555555ssssssssssssssssss"
      "sssssssssssssssss5555555565555655055000000500005555500001000000000000001000055555001150000005505555555555555555sssssssssssssssss"
      "ssssssssssssssss555555555566665550550000059990055555500171000000000000171005555550171050000055055555555555555555ssssssssssssssss"
      "sssssssssssssjsj555555555511115555500000050010055555500010000000000000010005555550010050000055055555555555555555jsjsssssssssssss"
      "ssssssssssssssjj555555555044440555500000500171055555550000010000000010000055555550171050000005550000001155555555jjssssssssssssss"
      "sssssssssssjsjsj555555550487884055500000500110055555556000171000000171000655555550011050000005550005567655555555jsjsjsssssssssss"
      "ssssssssssssjjj05555555504888840550000050017105555555550000100000000100005555555550171050000055500055676555555550jjjssssssssssss"
      "sssssssssjsjsjjj5055505504f88f4055000005000105555550555661000000000016166515515555555550000005550000001150555055jjjsjsjsssssssss"
      "ssssssssssjjj0j055555555048ff840550000050001655555555555566666666666666666666655550000000000005555555555555555550j0jjjssssssssss"
      "sssssssssjsjjj0j050505055644446505500000501655050515151556666655556666666666660000000000000000555555555505050505j0jjjsjsssssssss"
      "ssssssssjjj0j000555555555566665555000005666555555566666666666566665666666666660000000000000000555555555555555555000j0jjjssssssss"
      "sssssjsjsjjj0j0050505050505151505500000055555550006666666666566776656666666666000000000000000055505050505050505000j0jjjsjsjsssss"
      "ssssssjjj0j0000005050505050505055500000000000000006666666666567667656666666666000555500000000055050505050505050500000j0jjjssssss"
      "sssjsjsjjj0j00005050505050505050550000000000000000666666666656666665666666666655505055555000005550505050505050500000j0jjjsjsjsss"
      "ssssjjj0j00000000505050505050505550000000000000000666666666675666657666665151505050505055000005505050505050505050000000j0jjjssss"
      "sjsjsjjj0j000000000000000000000055000000000000055566666666666755557666100000000000000000500000550000000000000000000000j0jjjsjsjs"
      "ssjjj0j000000000050505050505050555000000000555550515151666666677776666050505050505050505000005550505050505050505000000000j0jjjss"
      "sjsjjj0j0000000000000000000000005500000555550000000000000166666666666100000000000000000500000550000000000000000000000000j0jjjsjs"
      "jjj0j0000000000000500050005000505500000500500050005000500051666666661050005000500050005500000550005000500050005000000000000j0jjj"
      "")
    (p8-section map
      "0000303030090a0b0c3030300000000000000015000000000000000000000000000000000000000000000000424343434343434343434344303030303030303030303030303030304546808182838485868788898a8b8c8dc0c1c2c3c4c5c6c7c800000000000000000000000000000000000000000000000000000000000000"
      "0000301718191a1b1c1718300500000002030400000000000000000000000000000000000000000000000000525353535353535353535354303030303030303030303030303030300000909192939495969798999a9b9c9dd0d1d2d3d4d5d6d7d800000000000000000000000000000000000000000000000000000000000000"
      "0000262728292a2b2c2d2e2f0000001500000000000000000000000000000000000000000000000000000000525353535353535353535354303030303030303030303030303030300000a0a1a2a3a4a5a6a7a8a9aaabacade0e1e2e3e4e5e6e7e800000000000000000000000000000000000000000000000000000000000000"
      "0000363738393a3b3c3d3e3f0000000000000000000000000013140000000000232400121314000000002324525353535353535353535354303030303030303030303030303030300000b0b1b2b3b4b5b6b7b8b9babbbcbdf0f1f2f3f4f5f6f7f800000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002400000000000000000000000023242324000023212223222124131400233132525353535353535353535354303030303030303030303030303030300000555657000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000161616161616161616161124001314131400000000002321221132242322313231323132232423222122525353535353535353535354303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002122242324232400002324232131322121223132112122212211313231323132525353535353535353535354303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000161616161616161616163132113132313224233132313132113131321121223132313221222122112122525353535353535353535354303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002535350000000000000000000006060771714151415141514151415141517171626363636363636363636364303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000161616161616161616164040404040404040404040404040404040404040404040404040404040404040306130303030303030306130303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000001010101010101010101010101010101010101010101010101010101010101010000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000001010101010101010101010101010101010101010101010101010101010101010000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000005050505050505050505050505050505050505050505050505050505050505050000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000006060606060606060606060606060606060606060606060606060606060606060000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000007070707070707070707070707070707070707070707070707070707070707070000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000303030303030303030303030303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000003030303030303030303030303030303000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002020202020202020202020202020202000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002020202020202020202020202020202000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002020202020202020202020202020202000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000002020202020202020202020202020202000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section sfx
      "650c00080933009430153301543009330094301533015430003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "050c00001d0531d01329600000001d4531d413286040000029634000001d0531d0131d4531d41339013000001d0531d01328604000001d4531d413286040000029634000001d0531d0131d4531d4133901329605"
      "050c00001d0531d01329600000001d4531d413286040000029634000001d0531d0131d4531d41339013000001d0531d01328604000001d4531d413286040000029634000001d0531d0131d4531d4132963529635"
      "110c00001c4551c4301a4551a4301c4551c43018455184301c4551c4301a4551a4301c4551c43018455184301c4551c4301a4551a4301c4551c43018455184301c4551c4301a4551a4301c4551c4302145021450"
      "650c00080433004430103301043004330044301033010430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "110c00001f4501f4501f4501f4501f4401f4401f4401f4401f4401f4401f4401f4401f4321f4321f4321f4321f4321f4321f4321f4321f4221f4221f4221f4201f4221f4221f4221f4221f4121f4121f4121f412"
      "650c00080733007430133301343007330074301333013430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "110c00001f4551f4301d4551d4301f4551f4301a4551a4301f4551f4301d4551d4301f4551f4301a4551a4301f4551f4301d4551d4301f4551f4301a4551a4301f4551f4301d4551d4301f4551f4301a4501a450"
      "110c00001c4501c4501c4501c4501c4401c4401c4401c4401c4401c4401c4401c4401c4321c4321c4321c43200000000001c4401c44000000000001c4401c44000000000001c4401c44000000000001c4401c440"
      "110c00001c4501c4501c4501c4501c4401c4401c4401c4401c4401c4401c4401c4401c4321c4321c4321c4321c4501c4551c4501c4501a4501a4501c4501c4501d4501d4501c4501c4501a4501a4501845018450"
      "050c00001d0531d01329600000001d4531d413286040000029634000001d0531d0131d4531d41339013000001d0531d01328604000001d4531d41339013000001d4431d4431a4431a44315443154431344313443"
      "290c00202875028750287502875028750287502875228752287422874228742287422873228732287322873228722287222871228712007000070000700007000070000700007000070026750267502475024750"
      "290c002026750267502675026750267502675023750237501f7501f7501f7501f7501f7421f7421f7421f7421f7321f7321f7321f7321f7221f7221f7121f7120070000700007000070000000000000000000000"
      "290c00202675026750267502675026750267502675026750267402674026740267402673226732267322673226722267222671226712007000070000700007000000000000000000000000000000000000000000"
      "290c00202675026750267502675026740267402674026740267322673226732267322672226722267122671200000000000000000000000000000000000000002875028750287502875026750267502675026750"
      "290c00202475024750247502475024750247502375023750217502175021750217502174021742217422174221732217322173221732217222172221712217122170021700217002170021750217502375023750"
      "650c00080533005430113301143005330054301133011430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "290c00202475024750247502475024740247422474224742247322473224732247322472224722247122471200000000000000000000000000000000000000002675026750267502675024750247502475024750"
      "650c00200733007430133301343007330074301333013430073300743013330134300733007430133301343008330084301433014430083300843014330144300833008430143301443008330084301433014430"
      "050c00001d0531d01329600000001d4531d413286040000029634000001d0531d0131d4531d41339013000001d4531d4531d4131c4531c4531c4131a4531a4531a4131845318453184131d4531c4531a45318453"
      "290c00202675026750267502675026750267502675026752267422674226742267422673226732267322673228750287502875028750287002870028750287502870228702287402874028702287022874028740"
      "110c00001533015330153301533015330153301533015330153301533015330153301532015322153221532215322153221532215322153221532215322153221531215312153121531215312153121531215312"
      "650c00000933009430153301543009330094301533015430093300943015330154200932009420153201542009320094201532015420093200941015310154100931009410153101541009310094101531015410")
    (p8-section music
      "00 00424344"
      "00 00424344"
      "00 00420144"
      "00 00420244"
      "00 00030144"
      "00 04050244"
      "00 06070144"
      "00 04080244"
      "00 00030144"
      "00 04050244"
      "00 06070144"
      "00 04090a44"
      "00 0057010b"
      "00 0458020c"
      "00 0057010b"
      "00 0458020d"
      "00 0659010e"
      "00 0057010f"
      "00 10420111"
      "00 12421314"
      "00 00030144"
      "00 04050244"
      "00 06070144"
      "00 04080a44"
      "00 00030144"
      "00 04050244"
      "00 06070144"
      "00 04091344"
      "00 00150144"
      "00 00420144"
      "00 00424344"
      "00 16424344"
      "00 29424344"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a2d2d206d4f542753206752414e44207052495820704c55530a2d2d206259206d4f540a2d2d207449544c4520615254204259206d4152434f2076414c450a0a676c6f623d7b0a095b2274727565225d3d747275652c0a095b2266616c7365225d3d66616c73650a7d0a0a66756e6374696f6e2064617461696e74286c696e65732c70726f70732c676c6f626e616d65290a206c6f63616c20643d7b7d0a20666f72206c20696e20616c6c286c696e65732920646f0a20206c6f63616c206f2c763d7b7d")
    (hex 256 "2c73706c6974286c290a2020666f7220692c76616c20696e2069706169727328762920646f0a20202069662076616c7e3d2222207468656e0a20202020696628676c6f625b76616c5d7e3d6e696c2976616c3d676c6f625b76616c5d0a092020206f5b70726f70735b695d5d3d76616c0a092020656e640a2020656e640a20206966206f2e6e616d65207468656e0a202009645b6f2e6e616d655d3d6f0a202009696628676c6f626e616d6529676c6f625b676c6f626e616d652e2e222e222e2e6f2e6e616d655d3d6f0a0909656e640a202061646428642c6f290a20656e640a2072657475726e20640a656e640a0a66756e6374696f6e2064617461287374")
    (hex 512 "722c676c6f626e616d65290a206c6f63616c206c696e65733d73706c6974287374722c63687228313029290a206c6f63616c2070726f70733d73706c69742864656c69286c696e65732c3129290a2072657475726e2064617461696e74286c696e65732c70726f70732c676c6f626e616d65290a656e640a0a66756e6374696f6e20646174616864722870726f707374722c7374722c676c6f626e616d65290a2072657475726e2064617461696e742873706c6974287374722c63687228313029292c73706c69742870726f70737472292c676c6f626e616d65290a656e640a0a66756e6374696f6e20736f72742861727261792c636f6d70666e290a20666f")
    (hex 768 "7220693d322c23617272617920646f0a20206c6f63616c20632c6a3d61727261795b695d2c690a20207768696c65206a3e3120616e6420636f6d70666e2861727261795b6a2d315d2c632920646f0a20202061727261795b6a5d3d61727261795b6a2d315d0a2020206a2d3d310a2020656e640a202061727261795b6a5d3d630a20656e640a656e640a0a2d2d2073686172656420616e696d6174696f6e20636f64650a2d2d20744849532054414220434f4e5441494e5320414c4c20434f4445200a2d2d204e454345535341525920544f204c4f414420414e4420504c41590a2d2d20414e494d4154494f4e532e0a0a2d2d20636f6e7374616e74730a616e")
    (hex 1024 "696d66696c657665723d310a0a2d2d20726f7574696e65730a0a66756e6374696f6e2072756e636f726f7574696e657328636f290a09666f72206320696e20616c6c28636f2920646f0a0909696620636f7374617475732863293d3d2264656164227468656e0a09090964656c28636f2c63290a0909656c73650a09090961737365727428636f726573756d65286329290a0909656e640a09656e640a656e640a0a66756e6374696f6e206c65727028612c622c66290a2072657475726e2028312d66292a612b662a620a656e640a0a65617365666e3d7b0a2066756e6374696f6e2876292072657475726e207620656e642c0a2066756e6374696f6e287629")
    (hex 1280 "2072657475726e20202d73696e28762f342920656e642c0a2066756e6374696f6e2876292072657475726e20312d636f7328762f342920656e642c0a2066756e6374696f6e2876292072657475726e20302e352d636f7328762f32292f3220656e640a7d0a0a66756e6374696f6e20636c616d7028762c6d6e2c6d78290a0972657475726e206d696e286d617828762c6d6e292c6d78290a656e640a0a66756e6374696f6e20737072636f6f726473286e290a0972657475726e20286e253136292a382c666c72286e2f3136292a380a656e640a0a66756e6374696f6e2074696c65636f6f726473286e290a2072657475726e206e253132382c666c72286e2f")
    (hex 1536 "313238290a656e640a0a66756e6374696f6e20736d61702863782c63792c63772c63682c73782c73792c73772c73682c666c6970782c666c697079290a202d2d2064656c74610a206c6f63616c2064782c64793d63772f73772c63682f73680a200a202d2d206170706c7920666c69700a20696620666c697078207468656e0a202063782b3d63770a202064783d2d64780a20656e640a20696620666c697079207468656e0a202063792b3d63680a202064793d2d64790a20656e640a200a206c6f63616c2078302c78313d73782c73782b73770a206c6f63616c2079302c79313d73792c73792b73680a2063782b3d286365696c287830292d7830292a6478")
    (hex 1792 "0a2063792b3d286365696c287930292d7930292a64790a2078302c79302c78312c79313d6365696c287830292c6365696c287930292c6365696c287831292d312c6365696c287931292d310a0a202d2d2072656e646572207769746820746c696e65730a20666f7220793d79302c793120646f0a2020746c696e652878302c792c78312c792c63782c63792c64782c30290a202063792b3d64790a20656e640a656e640a0a2d2d2066696c6520692f6f0a0a2d2d2073747265616d2068656c706572730a0a66756e6374696f6e2072656164322873656c66290a2072657475726e2073656c663a726561643128297c2873656c663a726561643128293c3c3829")
    (hex 2048 "0a656e640a0a2d2d206d656d6f72792073747265616d0a0a66756e6374696f6e206d656d5f73697a652873656c66290a0972657475726e2073656c662e616464722d73656c662e62617365616464720a656e640a0a66756e6374696f6e206d656d5f72312873656c66290a206c6f63616c20763d7065656b2873656c662e61646472290a2073656c662e616464722b3d310a2072657475726e20760a656e640a0a66756e6374696f6e20726561646d656d73747265616d2861646472290a0972657475726e207b0a090962617365616464723d616464722c0a0909616464723d616464722c0a090973697a653d6d656d5f73697a652c0a090972656164313d6d")
    (hex 2304 "656d5f72312c0a090972656164323d72656164320a097d0a656e640a0a2d2d2068657820737472696e672073747265616d0a0a66756e6374696f6e2066726f6d686578636861722863290a2072657475726e206f72642863292d28633e22392220616e64203837206f72203438290a656e640a0a66756e6374696f6e207374725f73697a652873656c66290a0972657475726e202373656c662e7374722f320a656e640a0a66756e6374696f6e207374725f72312873656c66290a206c6f63616c207374722c6f6666733d73656c662e737472735b666c722873656c662e6f6666733e3e3130292b315d2c73656c662e6f6666732630783366660a206f666673")
    (hex 2560 "2b3d310a206c6f63616c2068693d66726f6d6865786368617228737562287374722c6f6666732c6f66667329290a206f6666732b3d310a206c6f63616c206c6f3d66726f6d6865786368617228737562287374722c6f6666732c6f66667329290a2073656c662e6f6666732b3d320a2072657475726e202868693c3c34297c6c6f0a656e64200a0a66756e6374696f6e207265616473747273747265616d2873747273290a0972657475726e207b0a0909737472733d737472732c0a09096f6666733d302c0a090973697a653d7374725f73697a652c0a090972656164313d7374725f72312c0a090972656164323d72656164320a097d0a656e640a0a2d2d20")
    (hex 2816 "68656c7065722066756e6374696f6e730a0a66756e6374696f6e207265616473747266697865642873747265616d2c6c656e290a096c6f63616c20726573756c743d22220a09666f7220693d312c6c656e20646f0a0909726573756c742e2e3d6368722873747265616d3a72656164312829290a09656e640a0972657475726e20726573756c740a656e640a0a66756e6374696f6e20726561647374722873747265616d290a096c6f63616c206c656e3d73747265616d3a726561643128290a0972657475726e207265616473747266697865642873747265616d2c6c656e290a656e640a0a2d2d2066696c6520696f0a0a66756e6374696f6e206c6f616461")
    (hex 3072 "6e696d732873747265616d290a097072696e746828222a2a2a206c6f6164696e6720616e696d6174696f6e73202a2a2a22290a0a092d2d207665726966792068656164657220616e642076657273696f6e0a096c6f63616c206864723d7265616473747266697865642873747265616d2c33290a096966206864727e3d226d617322207468656e0a09097072696e74682822276d61732720686561646572206e6f7420666f756e6422290a090973746f7028290a09656e640a090a096c6f63616c207665723d73747265616d3a726561643128290a096966207665723e616e696d66696c65766572207468656e0a09097072696e74682822756e737570706f72")
    (hex 3328 "7465642066696c652076657273696f6e3a20222e2e766572290a090973746f7028290a09656e640a090a092d2d206c6f6164206561636820616e696d6174696f6e0a096c6f63616c2063743d73747265616d3a726561643128290a096c6f63616c20616e696d733d7b7d0a09666f7220693d312c637420646f0a09096c6f63616c207479703d73747265616d3a726561643128290a09096c6f63616c20616e696d0a09096966207479703d3d31207468656e0a090909616e696d3d6c6f6164737072697465616e696d2873747265616d290a0909656c73650a090920616e696d3d6c6f6164746c616e696d2873747265616d2c747970290a0909656e640a0909")
    (hex 3584 "61646428616e696d732c616e696d290a0909616e696d735b616e696d2e6e616d655d3d616e696d0a09656e640a090a092d2d20636f6e7665727420696e646963657320696e746f207265666572656e6365730a09666f7220616e696d20696e20616c6c28616e696d732920646f0a0920696620616e696d2e7479707e3d2273707269746522207468656e0a092020666f7220746c20696e20616c6c28616e696d2e746c732920646f0a09202020666f72206b20696e20616c6c28746c2e6b65796672616d65732920646f0a09202020206b2e616e696d3d6b2e616e696d20616e6420616e696d735b6b2e616e696d5d0a09202020656e640a092020656e640a09")
    (hex 3840 "20656e640a20656e640a0a0972657475726e20616e696d730a656e640a0a66756e6374696f6e206c6f6164737072697465616e696d2873747265616d290a096c6f63616c20616e696d3d6d616b65737072697465616e696d28290a090a092d2d2070726f706572746965730a09616e696d2e6e616d653d726561647374722873747265616d290a09616e696d2e6670733d73747265616d3a726561643128292f340a09616e696d2e773d73747265616d3a726561643128290a09616e696d2e683d73747265616d3a726561643128290a09616e696d2e6f783d73747265616d3a726561643128292f3130300a09616e696d2e6f793d73747265616d3a72656164")
    (hex 4096 "3128292f3130300a09616e696d2e74723d73747265616d3a726561643128290a0a092d2d206672616d65730a09616e696d2e6672616d65733d7b7d0a096c6f63616c2063743d73747265616d3a726561643128290a09666f7220693d312c637420646f0a09096c6f63616c206672616d653d7b7d0a09096672616d652e6672616d653d73747265616d3a726561643228290a09096c6f63616c20666c6167733d73747265616d3a726561643128290a09096672616d652e666c6970783d28666c6167732631293d3d310a09096672616d652e666c6970793d28666c6167732632293d3d320a090961646428616e696d2e6672616d65732c6672616d65290a0965")
    (hex 4352 "6e640a090a0972657475726e20616e696d2020200a656e640a0a66756e6374696f6e206c6f6164746c616e696d2873747265616d2c747970290a206c6f63616c20616e696d3d6d616b65746c616e696d28290a206966287479703d3d3329616e696d2e7479703d2273746f7279626f617264220a200a092d2d2070726f706572746965730a09616e696d2e6e616d653d726561647374722873747265616d290a09616e696d2e643d73747265616d3a726561643228292f3130300a090a092d2d2074696d656c696e65730a09616e696d2e746c733d7b7d0a096c6f63616c2063743d73747265616d3a726561643128290a09666f7220693d312c637420646f0a")
    (hex 4608 "09206c6f63616c206b65796672616d65733d7b7d0a09206c6f63616c206b63743d73747265616d3a726561643128290a0920666f72206a3d312c6b637420646f0a09200a0920202d2d2074696d650a0920206c6f63616c20743d73747265616d3a726561643228292f3130300a0920206c6f63616c206b3d6d616b656b65796672616d652874290a0920200a0920202d2d20636f6e74656e74200a0920206c6f63616c20666c6167733d73747265616d3a726561643128290a09202069662028666c6167732631297e3d30207468656e200a092020096b2e616e696d3d73747265616d3a7265616431282909092d2d2077696c6c20626520636f6e7665727465")
    (hex 4864 "6420746f206f626a656374207265666572656e6365206c617465720a090909656e640a09202069662028666c6167732632297e3d30207468656e0a092020096b2e783d73747265616d3a726561643228290a092020096b2e793d73747265616d3a726561643228290a092020656e640a09202069662028666c6167732634297e3d30207468656e0a092020206b2e787363616c653d73747265616d3a726561643228292f3130300a092020206b2e797363616c653d73747265616d3a726561643228292f313030092020200a092020656e640a09202069662028666c6167732638297e3d30207468656e0a092020206b2e616e696d743d73747265616d3a7265")
    (hex 5120 "61643228292f3130300a092020206b2e616e696d7370643d73747265616d3a726561643228292f3130300a092020656e64200a0920200a0920202d2d20737461746520666c6167730a092020666c6167733d73747265616d3a726561643128290a0920206b2e666c6970783d28666c6167732631297e3d300a0920206b2e666c6970793d28666c6167732632297e3d300a0920206b2e76697369626c653d28666c6167732634297e3d300a0920206b2e6c6f6f703d28666c6167732638297e3d300a0920206b2e65617365696e3d28666c616773263136297e3d300a0920206b2e656173656f75743d28666c616773263332297e3d300a0920200a0920206b2e")
    (hex 5376 "7461673d73747265616d3a726561643128290a0920200a092020616464286b65796672616d65732c6b290a0920656e640a092061646428616e696d2e746c732c7b6b65796672616d65733d6b65796672616d65737d2909200a09656e640a090a092d2d206576656e74730a09616e696d2e6576656e74732e6b65796672616d65733d7b7d0a096c6f63616c2063743d73747265616d3a726561643128290a09666f7220693d312c637420646f0a090a20202d2d2074696d650a20206c6f63616c20743d73747265616d3a726561643228292f3130300a09206c6f63616c206b3d6d616b656576656e742874290a09200a09202d2d20747970650a09206b2e7479")
    (hex 5632 "703d726561647374722873747265616d290a09206c6f63616c20666c6167733d73747265616d3a726561643128290a092069662028666c6167732631297e3d30207468656e0a2020096b2e783d73747265616d3a726561643228290a2020096b2e793d73747265616d3a726561643228290920090a2020656e640a202069662028666c6167732632297e3d30207468656e0a2020206b2e6e3d73747265616d3a726561643128290a2020656e640a202069662028666c6167732634297e3d30207468656e0a2020206b2e7478743d726561647374722873747265616d290a2020656e6409200a202061646428616e696d2e6576656e74732e6b65796672616d65")
    (hex 5888 "732c6b290a09656e640a090a0972657475726e20616e696d0a656e640a0a2d2d2073707269746520616e696d6174696f6e730a0a66756e6374696f6e2064726177616e696d280a090973656c662c0a0909742c0a0909782c792c0a0909787363616c652c797363616c652c0a0909666c6970782c666c6970792c0a09096474290a09090a2073656c663a646f64726177280a200974206f7220302c0a200978206f722036342c0a200979206f722036342c0a2009787363616c65206f7220312c0a2009797363616c65206f7220312c0a2009666c6970782c0a2009666c6970792c0a20096474206f7220312f285f75706461746520616e64203330206f722036")
    (hex 6144 "30292c0a200930290a656e640a0a66756e6374696f6e20737072697465616e696d5f647261772873656c662c742c782c792c787363616c652c797363616c652c666c6970782c666c697079290a0a092d2d2066696e64206672616d650a096c6f63616c20663d636c616d7028666c7228742a73656c662e667073292b312c312c2373656c662e6672616d6573290a096c6f63616c206672616d653d73656c662e6672616d65735b665d0a0a092d2d20646973706c617920776964746820616e64206865696768740a096c6f63616c2064772c64683d73656c662e772a382a787363616c652c73656c662e682a382a797363616c650a090a092d2d20666c697020")
    (hex 6400 "666c6167730a096966286672616d652e666c69707829666c6970783d6e6f7420666c6970780a096966286672616d652e666c69707929666c6970793d6e6f7420666c6970790a0a092d2d2061646a75737420666f72206f7267696e2070740a09782d3d64772a28666c69707820616e642028312d73656c662e6f7829206f722073656c662e6f78290a09792d3d64682a28666c69707920616e642028312d73656c662e6f7929206f722073656c662e6f79290a0a092d2d20647261770a092d2d2061732074696c656d617020636f6f7264730a0970616c7428302c66616c7365290a0970616c742873656c662e74722c74727565290a096c6f63616c2063782c")
    (hex 6656 "63793d74696c65636f6f726473286672616d652e6672616d65290a09736d6170280a092063782c63792c0a092073656c662e772c73656c662e682c0a0920782c792c0a092064772c64682c0a0920666c6970782c666c697079290a2070616c742873656c662e74722c66616c736529090a0970616c7428302c74727565290a656e640a0a66756e6374696f6e20737072697465616e696d5f6475726174696f6e2873656c66290a0972657475726e202373656c662e6672616d65732f73656c662e6670730a656e640a0a66756e6374696f6e206d616b65737072697465616e696d28290a0972657475726e207b0a09097479703d22737072697465222c0a0909")
    (hex 6912 "6e616d653d22737072697465222c0a09096670733d31302c0a0909773d312c683d312c0a09096f783d302e352c6f793d302e352c0a090974723d31362c0a09096672616d65733d7b0a0909096d616b657370726974656672616d652831292c0a09097d2c0a09096475726174696f6e3d737072697465616e696d5f6475726174696f6e2c0a0909646f647261773d737072697465616e696d5f647261772c0a0909647261773d64726177616e696d0a097d0a656e640a0a66756e6374696f6e206d616b657370726974656672616d65286e290a0972657475726e207b0a09096672616d653d6e2d2d2c0a2d2d0909666c6970783d66616c73652c0a2d2d090966")
    (hex 7168 "6c6970793d66616c73650a097d0a656e640a0a2d2d2074696d656c696e656420616e696d6174696f6e730a0a66756e6374696f6e20746c616e696d5f6475726174696f6e2873656c66290a0972657475726e2073656c662e640a656e640a0a6b65796672616d657377697463683d73706c69742822616e696d2c616e696d742c616e696d7370642c74616722290a6b65796672616d656c6572703d73706c69742822782c792c787363616c652c797363616c6522290a6b65796672616d65666c6167733d73706c69742822666c6970782c666c6970792c76697369626c652c6c6f6f7022290a0a66756e6374696f6e2066696e647265666b65796672616d6573")
    (hex 7424 "28746c2c70726f702c74290a202d2d2066696e64206e656172657374206672616d6573206265666f72652f616674657220740a202d2d2077686572652070726f7065727479206973206e6f74206e756c6c0a206c6f63616c206265666f72652c61667465720a206c6f63616c206265666f7265742c6166746572743d2d313030302c313030300a20666f72206b20696e20616c6c28746c2e6b65796672616d65732920646f0a20206966206b5b70726f705d207468656e0a2020206966206b2e743c3d7420616e64206b2e743e6265666f726574207468656e0a202020206265666f72652c6265666f7265743d6b2c6b2e740a202020656e640a202020696620")
    (hex 7680 "6b2e743e7420616e64206b2e743c616674657274207468656e0a2020202061667465722c6166746572743d6b2c6b2e740a202020656e640a2020656e640a20656e640a2072657475726e206265666f72652c61667465720a656e640a0a66756e6374696f6e206765747669727475616c6b65796672616d6528746c2c74290a0a202d2d2063616c63756c6174652074686520656666656374697665200a202d2d20227669727475616c22206b65796672616d652061742074696d6520740a202d2d206f6e207468652074696d656c696e652c20696e746572706f6c6174696e670a202d2d206173206e65636573736172792e0a206c6f63616c2070726f70733d")
    (hex 7936 "7b0a202076697369626c653d747275652c0a2020616e696d743d302c616e696d7370643d312c0a2020783d302c793d302c0a2020787363616c653d312c797363616c653d312c0a2020666c6970783d66616c73652c666c6970793d66616c73652c0a202065617365696e3d66616c73652c656173656f75743d66616c73650a207d0a0a092d2d207377697463686f7665722070726f706572746965730a206c6f63616c20616e696d7474090909090a09666f722070726f7020696e20616c6c286b65796672616d657377697463682920646f0a09206265666f72652c61667465723d66696e647265666b65796672616d657328746c2c70726f702c74290a0920")
    (hex 8192 "6c6f63616c206672616d653d6265666f7265206f722061667465720a09206966286672616d652970726f70735b70726f705d3d6672616d655b70726f705d0a090969662070726f703d3d22616e696d7422207468656e0a090920616e696d74743d6265666f726520616e64206265666f72652e740a0909656e640a09656e640a0a092d2d20696e746572706f6c617465642070726f706572746965730a09666f722070726f7020696e20616c6c286b65796672616d656c6572702920646f0a09206265666f72652c61667465723d66696e647265666b65796672616d657328746c2c70726f702c74290a20206966206265666f726520616e6420616674657220")
    (hex 8448 "7468656e0a2020206c6f63616c20663d28742d6265666f72652e74292f2861667465722e742d6265666f72652e74290a20202069662070726f703d3d227822206f722070726f703d3d227922207468656e0a202020206c6f63616c20653d310a2020202069662861667465722e65617365696e29652b3d310a202020206966286265666f72652e656173656f757429652b3d320a20202020663d65617365666e5b655d2866290a202020656e640a20202070726f70735b70726f705d3d6c657270286265666f72655b70726f705d2c61667465725b70726f705d2c66290a2020656c73650a0909206c6f63616c206672616d653d6265666f7265206f72206166")
    (hex 8704 "7465720a0909206966286672616d652970726f70735b70726f705d3d6672616d655b70726f705d0a0909656e6409090920200a09656e640a090a092d2d20666c6167730a096265666f72652c61667465723d66696e647265666b65796672616d657328746c2c2274222c74290a096c6f63616c206b3d6265666f7265206f722061667465720a096966206b207468656e200a0920666f722070726f7020696e20616c6c286b65796672616d65666c6167732920646f0a09202070726f70735b70726f705d3d6b5b70726f705d0a0920656e640a09656e640a090a092d2d2063616c63756c6174652065666665637469766520616e696d740a092d2d2061742074")
    (hex 8960 "696d6520742c2074616b696e6720696e746f206163636f756e740a092d2d20616e696d6174696f6e20737065656420616e206c6f6f70696e672e0a09696620616e696d7474207468656e0a092070726f70732e616e696d742b3d28742d616e696d7474292a70726f70732e616e696d7370640a09656e640a0969662070726f70732e6c6f6f7020616e642070726f70732e616e696d207468656e0a092070726f70732e616e696d74253d70726f70732e616e696d3a6475726174696f6e28290a09656e640a0972657475726e2070726f70730a656e640a0a66756e6374696f6e20746c616e696d5f647261772873656c662c742c782c792c787363616c652c79")
    (hex 9216 "7363616c652c666c6970782c666c6970792c64742c72290a202d2d20726563757273696f6e206c696d69740a20722b3d310a20696628723e3130292072657475726e0a200a202d2d206472617720616e696d7320666f7220656163682074696d656c696e650a20666f7220746c20696e20616c6c2873656c662e746c732920646f0a0a20202d2d2067657420656666656374697665206b65796672616d6520666f7220740a09096c6f63616c2070726f70733d6765747669727475616c6b65796672616d6528746c2c74290a09090a09092d2d2064726177206368696c6420616e696d6174696f6e0a090969662070726f70732e76697369626c6520616e6420")
    (hex 9472 "70726f70732e616e696d207468656e0a09090a0909202d2d2063616c63756c6174652065666665637469766520706f736974696f6e2c7363616c6520616e6420666c69700a0909206c6f63616c2063783d782b70726f70732e782a787363616c652a28666c69707820616e64202d31206f722031290a0909206c6f63616c2063793d792b70726f70732e792a797363616c652a28666c69707920616e64202d31206f722031290a0909206c6f63616c2063787363616c652c63797363616c653d787363616c652a70726f70732e787363616c652c797363616c652a70726f70732e797363616c650a0909206c6f63616c2063666c6970782c63666c6970793d66")
    (hex 9728 "6c6970782c666c6970790a20202069662870726f70732e666c6970782963666c6970783d6e6f742063666c6970780a20202069662870726f70732e666c6970792963666c6970793d6e6f742063666c6970790a2020206c6f63616c206364743d647420616e642064742a70726f70732e616e696d7370640a0909200a0909202d2d20647261770a0909206966206e6f7420616e696d5f64726177206f7220616e696d5f647261772870726f70732c63782c63792c63787363616c652c63797363616c652c63666c6970782c63666c6970792c6364742c7229207468656e0a0909092070726f70732e616e696d3a646f647261772870726f70732e616e696d742c")
    (hex 9984 "63782c63792c63787363616c652c63797363616c652c63666c6970782c63666c6970792c6364742c72290a090909656e640a0909656e6409090a09656e640a090a092d2d2074726967676572206576656e74730a096966206474207468656e0a0920666f72206b20696e20616c6c2873656c662e6576656e74732e6b65796672616d65732920646f0a0920206966206b2e743e742d647420616e64206b2e743c3d7420616e6420616e696d5f6576656e74735b6b2e7479705d207468656e0a20202020616e696d5f6576656e74735b6b2e7479705d286b2c782c79290a092020656e640a0920656e640a09656e64090a656e640a0a66756e6374696f6e206d61")
    (hex 10240 "6b656b65796672616d652874290a0972657475726e207b0a0909743d742c0a0909616e696d3d6e696c2c0a09096c6f6f703d747275652c0a090961667465723d66616c73652c0a2d2d0909616e696d743d6e696c2c0a2d2d0909616e696d7370643d6e696c2c0a2d2d0909783d6e696c2c0a2d2d0909793d6e696c2c0a2d2d0909787363616c653d6e696c2c0a2d2d0909797363616c653d6e696c2c0a090976697369626c653d747275652c0a0909666c6970783d66616c73652c0a0909666c6970793d66616c73652c0a090965617365696e3d66616c73652c0a0909656173656f75743d66616c73652c0a09097461673d300a097d0a656e640a0a66756e63")
    (hex 10496 "74696f6e206d616b656576656e7428742c747970290a2072657475726e207b0a2020743d742c0a20207479703d22222d2d2c0a2d2d2020783d6e696c2c0a2d2d2020793d6e696c2c0a2d2d20206e3d6e696c2c0a2d2d20207478743d6e696c0a207d0a656e640a0a66756e6374696f6e206d616b65746c28290a0a202d2d2064656661756c74206b65796672616d650a206c6f63616c206b3d6d616b656b65796672616d652830290a206b2e616e696d742c6b2e616e696d7370642c6b2e782c6b2e793d302c312c302c300a200a0972657475726e207b0a09096b65796672616d65733d7b6b7d090a097d0a656e640a0a66756e6374696f6e206d616b65746c")
    (hex 10752 "616e696d28290a0972657475726e207b0a09097479703d22746c222c0a09096e616d653d2274696d656c696e65222c0a0909643d31302c0a0909746c733d7b206d616b65746c2829207d2c0a09096576656e74733d7b206b65796672616d65733d7b7d207d2c0a09096475726174696f6e3d746c616e696d5f6475726174696f6e2c0a0909646f647261773d746c616e696d5f647261772c0a0909647261773d64726177616e696d0a097d0a656e640a0a2d2d206576656e74730a0a646f200a206c6f63616c2061667465726672616d65636f3d7b7d0a096c6f63616c2066756e6374696f6e20646f61667465726672616d6528666e290a0909206164642861")
    (hex 11008 "667465726672616d65636f2c636f63726561746528666e29290a20656e640a200a20616e696d5f6576656e74733d7b0a20207366783d66756e6374696f6e28657629097366782865762e6e29202020202020202020656e642c0a20206d75733d66756e6374696f6e28657629206d757369632865762e6e206f72202d312920656e642c0a20207478743d66756e6374696f6e286576290a202020646f61667465726672616d652866756e6374696f6e28290a20202020666f7220693d312c65762e6e206f7220333020646f0a20202020207072696e742865762e7478742c65762e782c65762e79290a20202020207969656c6428290a20202020656e640a2020")
    (hex 11264 "20656e64290a0909656e642c0a202072656c7478743d66756e6374696f6e2865762c782c79290a202020646f61667465726672616d652866756e6374696f6e28290a20202020666f7220693d312c65762e6e206f7220333020646f0a20202020207072696e742865762e7478742c782b2865762e78206f722030292c792b2865762e79206f72203029290a20202020207969656c6428290a20202020656e640a202020656e64290a0909656e642c0a0909636c723d66756e6374696f6e28290a09092061667465726672616d65636f3d7b7d0a0909656e642c0a0a09092d2d207363686564756c6520636f646520746f20657865637574652061667465722074")
    (hex 11520 "6865206672616d650a09092d2d2063616e20757365207969656c64282920746f2065786563757465206166746572206d756c7469706c65206672616d65730a0909646f61667465726672616d653d646f61667465726672616d652c0a20200a20202d2d2063616c6c207468697320616674657220746865206672616d652069732072656e64657265640a09096672616d65646f6e653d66756e6374696f6e28290a09092072756e636f726f7574696e65732861667465726672616d65636f290a0909656e640a207d0a656e640a2d2d3e380a2d2d20646174612f636f6e7374616e74730a0a2d2d20636f6e7374616e74730a747970655f726163652c74797065")
    (hex 11776 "5f746f75722c747970655f707261633d312c322c330a0a2d2d20646174610a747261636b6e616d65733d73706c697428226252414e44532068415443482c684f434b454e4845494d2c6d4f4e5a412c73494c56455253544f4e452c735041206652414e434f524348414d50532c73555a554b4122290a72616365747970656e616d65733d73706c6974282273494e474c4520724143452c6348414d50494f4e534849502c705241435449434522290a7261636574797065616e696d733d73706c69742822726163652c746f752c7072616322290a6469666e616d65733d73706c69742822654153592c6d454449554d2c684152442c65585045525422290a6c61")
    (hex 12032 "706f7074696f6e733d73706c69742822312c332c352c31302c323022290a726163657074733d73706c6974282231352c31322c31302c382c362c342c322c3122290a6672616d653d300a0a70616c733d64617461280a5b5b322c332c31302c31312c31340a3133312c3134302c322c3133392c330a352c352c352c352c355d5d290a0a61696361726e616d65733d73706c69742822732e20685544534f4e2c642e2076454c4f5045522c682e20704f545445522c762e206943452c702e2062524147412c6d2e20704f5745522c6d2e20635241422c722e206252554e542c7a2e206c45582c642e2073454542532c622e20615354524f2c732e206845494e5249")
    (hex 12288 "43482c6c2e206741524349412c732e2063415422290a0a616963617270616c733d64617461280a5b5b372c392c340a302c31312c300a302c382c300a31352c342c310a382c31352c380a342c392c340a362c302c310a362c372c360a372c392c340a312c31332c370a392c382c380a372c31342c320a372c382c340a31302c31342c310a372c332c315d5d290a0a616e696d646174613d7b0a22366436313733303132643031303436323639373236343137303130313332333230633034343830303030343930303030343930303030343930303030303130393632366636313732363436323631363336623238306330613332303030633031326330303030")
    (hex 12544 "30313033363336313732323830613034333236343063303130323030303030313035363336633666373536343238303330313332333231303031393030303030303130363633366336663735363437333238303830333332303031303031306330303030303130353637373236313665363432383065303433323332306330313461303030303031303736383666373236393761366636653238313030613332303031303031386330373030303130343664366637343733323830333031333233323063303134613032303030313034373037323639373832383039303433323332306330313538303030303031303437323666363136343238313030373332")
    (hex 12800 "33323130303130633034303030313035373236663631363433323238313030373332333231303031316330343030303130333733366237393238313031303332333231303031333830303030303130343734363537383734323830613035333230303130303138323032303030313035373436353738373433323238306130353030303031303031383230323030303130353734373236353635373332383130303533323634313030313863303130303031303637343732363536353733333232383130303533323634313030313963303130303033303537333734363137323734633230313031303330303030306231363030303030303030303030303634")
    (hex 13056 "30303034303063383030303931373030303036343030303430306463303030393234303030303634303030343030303030323033363236373331653830333035303130303030306230373030303063306666303030303634303030633030303130303030306230353030303063306666303030303634303030633030303130303030306230663030303066306666303030303634303030633031303130303030306230663030303031303030303030303634303030633030303130303030306230613030303032343030303030303634303030633030303130303030303436373732363137393032303230323037363236373331363136653639366462383062")
    (hex 13312 "30323031303030303062313230303030303030303030303036343030306330303036303030303062303163326666636566663030303036343030306330306634303130366636666663616666363430303561303030633030653830333036306530306435666633323030333230303138303032373035303731353066303062646666363430303561303030633030643630363032323230306339222c0a226666306330303030303930323464303063396666303830303030303230333632363733326538303330363031303030303062303730303030633066663030303036343030306330303031303030303062303565366666636466663030303036343030")
    (hex 13568 "30643030303130303030306230343233303064646666303030303634303030633030303130303030306231303030303066306666303030303634303030633031303130303030306231303030303031303030303030303634303030633030303130303030306230623030303032343030303030303634303030633030303030323035363236393732363437336338303030333031303030303062303130303030303030303030303036343030306330303031303030303062303166376666666466663061303036343030306330303031303030303062303130353030666166663738303036343030306330303030303230353632366336313665366263383030")
    (hex 13824 "30313031303030303061303030303030303030303030363430303063303030303032303636363631363436353639366531343030303130313030303030613030303030303030303030303634303030633030303130613030303336363639366530303032303436393634366336353634303030323031303030303062316530303030303030303030303036343030306330633031303030303062313930303030313430303030303036343030306330303030303230343664363536653735653830333031303130303030306230643030303030303030303030303634303030633165303030323038373037323631363336393634366336356538303330323031")
    (hex 14080 "30303030306231323030303030303030303030303634303030633030303130303030306232353030303030303030363430303634303030343030303030323036373037323631363336393665363430303032303130303030306231323030303030303030303030303634303030633030303130303030306232353030303030303030303030303634303030343030303030323037373037323631363336663735373436343030303130323030303030663132303030303030303036343030363430303030303036343030306330303634303030343230303332303033306330303030303230373730373236313633373037323635653830333031303130303030")
    (hex 14336 "3062313230303030303030303030303036343030306330303030303230383732363136333635363936343663363536343030303330313030303030623132303030303030303030303030363430303063303030313030303030623033303030303130303030303030363430303063303030313030303030623235303030303030303036343030363430303034303030303032303637323631363336353639222c0a2236653634303030333031303030303062313230303030303030303030303036343030306330303032303030303066303330303030313030303034303030343030303030303634303030633030363430303034363430303634303030633030")
    (hex 14592 "30313030303030623235303030303030303030303030363430303034303030303032303737323631363336353666373537343634303030313031303030303062316530303030303030303030303036343030306330303030303230373732363136333635373037323635363430303031303130303030306231323030303030303030303030303634303030633030303030323036373336333666373236353733363430303031303130303030306230653030303030303030303030303634303030633166303030323037373336333666373236353733363631343030303130323030303030623232303030303030303030303030363430303038303030613030")
    (hex 14848 "30303063303030303032303937333734363137323734366436313639366565363030303230333030303030623231303030303030303030303030363430303063306136343030303931663030303036343030303430626338303030393165303030303634303030633063303330303030306231393030303030303030303030303634303030383030616630303032303030303430303030633030653630303032303030303134303031633030303030323035373436393734366336353634303030333033313930303062303638306666636666663030303036343030306330303462303030323030303063666666316330303030303030303038303030333238")
    (hex 15104 "30303062303938303030653166663030303036343030306330303561303030323030303065316666316330303032303030303038303030323165303030623038313430306235666630303030363430303063303034643030303231343030633566663163303030303032303737343666373536323631363336623634303030323031303030303062313430303030303030303030303036343030306330303031303030303062303230303030633166663030303036343030306330303030303230373734366637353639363436633635363430303032303130303030306232363030303030303030303030303634303030633030303130303030306232326437")
    (hex 15360 "666663346666303030303634303030633030303030323035373436663735363936653634303030323031303030303062323630303030303030303030303036343030306330303033303030303062323364376666633466663030303036343030303830303332303030383030303039363030306330303462303030383030303036343030306330303030303230373734366637353664363136393665653830333031222c0a22303130303030306232373030303030303030303030303634303030633030303030323036373436663735366637353734363430303031303130303030306232373030303030303030303030303634303030343030303030323036")
    (hex 15616 "37343666373537303732363536343030303130313030303030623236303030303030303030303030363430303063303030303032303837343732363136653663363536363734386330303033303230303030306232373030303030303030303030303634303032633136346230303032383030303030303031383030303430303030306232313830666630303030303030303634303032633061346230303032303030303030303031343062393630303031316530633063323330303039316630303030363430303063306230313030303030623139303030303134303030303030363430303063303030303032303937343732363136653732363936373638")
    (hex 15872 "373438633030303330323030303030623231303030303030303030303030363430303263313634623030303238306666303030303138303030343030303030623262383030303030303030303030363430303263306134623030303230303030303030303134306239363030303132373063306332333030303932383030303036343030306330623031303030303062313930303030313430303030303036343030306330303030222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22222c0a22227d0a2d2d3e380a2d2d206d61696e0a0a66756e6374696f6e205f696e697428290a2063")
    (hex 16128 "6172746461746128226d6f745f67707022290a200a202d2d206c6f616420616e696d6174696f6e730a206c6f63616c2073747265616d3d7265616473747273747265616d28616e696d64617461290a20616e696d733d6c6f6164616e696d732873747265616d290a20616e696d5f6576656e74732e66696e3d66616465696e0a0a202d2d206c6f6164206361727420646174610a200a202d2d2067616d652073746174650a2069662064676574283130293d3d30207468656e0a090972616365747970652c6469662c6c61706f7074696f6e2c747261636b6e756d3d312c322c322c310a09656c736509090a09207261636574797065093d6467657428313029")
    (hex 16384 "0a20096469660909090909093d64676574283131290a0920747261636b6e756d093d64676574283132290a20096c61706f7074696f6e3d64676574283133290a20656e640a200a202d2d20746f75726e616d656e742073746174650a206c6f6164746f75726e616d656e7428290a0a202d2d2075706461746520746f75726e616d656e742073746174732077697468206c617374207261636520726573756c74730a206966202064676574283330293d3d3109090909092020202020202020202d2d207261636520656e646564200a20616e642064676574283138293d3d3020090909092020202020202020202d2d206e6f742064656d6f206d6f64650a2061")
    (hex 16640 "6e642072616365747970653d3d747970655f746f7572207468656e090a20096170706c7972616365726573756c747328290a20656e6420200a20647365742833302c30290a200a202d2d206d656e7520696e697469616c2073746174650a206d6f64652c6d656e75692c6d656e75792c64656d6f2c64656d6f6374723d227469746c65222c302c302c66616c73652c333135300a200a202d2d20706c617920737461727420616e696d6174696f6e0a206c6f63616c20616e696d7365743d6765746d6f6465616e696d736574287261636574797065290a20616e696d736574733d7b616e696d7365747d0a207472616e736974696f6e28616e696d735b227374")
    (hex 16896 "617274225d2c616e696d735b2269646c65225d290a200a202d2d206661646520696e206d757369630a206d7573696328302c3530303029200a656e640a0a66756e6374696f6e205f6472617728290a20636c7328290a206261736570616c28290a20696628616e696d20616e6420616e696d7429616e696d3a6472617728616e696d74290a20696628636f6e6669726d70726f6d70742964726177636f6e6669726d28290a20647261776661646528290a656e640a0a66756e6374696f6e205f75706461746528290a206672616d652b3d310a200a202d2d2063616e277420757064617465207768696c65207472616e736974696f6e696e670a206966206e6f")
    (hex 17152 "742069737472616e736974696f6e207468656e0a2020696620636f6e6669726d70726f6d7074207468656e0a202020757064617465636f6e6669726d28290a2020656c73656966206d6f64653d3d227469746c6522207468656e0a0920097570646174656d656e7528290a0920656e640a09656e640a200a202d2d20647269766520616e696d6174696f6e0a20696620616e696d74207468656e200a0920616e696d742b3d312f33300a092069662069737472616e736974696f6e20616e6420616e696d743e3d616e696d3a6475726174696f6e2829207468656e0a09200a0920202d2d20656e64207472616e736974696f6e0a202020696628646f6e65616e")
    (hex 17408 "696d29616e696d2c616e696d743d646f6e65616e696d2c300a202020696628646f6e65666e29646f6e65666e2829200a202020646f6e65616e696d2c646f6e65666e3d6e696c2c6e696c0a20202069737472616e736974696f6e3d66616c73650a0920656e640a09656e6409200a0a202d2d207570646174652066616465090a207570646174656661646528290a656e640a0a66756e6374696f6e2072756e67616d652864656d6f290a0a2069662072616365747970653d3d747970655f72616365207468656e0a2009726f737465723d6d616b6572616e646f6d726f7374657228290a20656c736569662072616365747970653d3d747970655f746f757220")
    (hex 17664 "7468656e0a2020726f737465723d746f75722e726f737465720a20656c73650a2020726f737465723d6e696c0a20656e640a0a202d2d207061737320706172616d657465727320746f2067616d650a202d2d2073746f72656420696e20646966666572656e74206461746120736c6f7473207468616e20757365640a202d2d20746f20706572736973742076616c756573206265747765656e2073657373696f6e732e0a202d2d207468697320697320736f2064656d6f2063616e20696e766f6b6520612072616e646f6d20747261636b0a202d2d20776974686f7574206f76657277726974696e67207573657227732070726566732e0a2064736574283134")
    (hex 17920 "2c7261636574797065290a20647365742831352c646966290a20647365742831362c64656d6f20616e642031206f72206c61706f7074696f6e735b6c61706f7074696f6e5d290a206c6f63616c20747261636b690a2069662072616365747970653d3d747970655f746f7572207468656e0a2020747261636b693d746f75722e747261636b735b746f75722e747261636b6e756d5d0a20656c73650a2020747261636b693d747261636b6e756d0a09656e640a09647365742831372c747261636b69290a20647365742831382c64656d6f20616e642031206f722030290a0a202d2d207061737320726f737465720a20696620726f73746572207468656e0a09")
    (hex 18176 "20666f7220692c6320696e2069706169727328726f737465722920646f0a092020647365742831392b692c63290a0920656e640a09656e640a090a092d2d20756e7061636b20747261636b206461746120696e746f2068696768206d656d6f72790a096d656d736574283078383030302c302c307837666666290a096c6f63616c20646174613d747261636b646174615b747261636b695d0a09666f7220693d312c236461746120646f0a0920706f6b65283078383030302b692d312c6f726428646174612c6929290a09656e640a200a202d2d2072756e2067616d650a206c6f61642822236d6f745f6772616e64707269783267616d6522290a656e640a0a")
    (hex 18432 "616e696d7365746e616d65733d73706c697428227072652c5f696e2c69646c652c6f757422290a0a66756e6374696f6e20616e696d5f647261772870726f70732c63782c63792c63787363616c652c63797363616c652c63666c6970782c63666c6970792c6364742c72290a206c6f63616c207461673d70726f70732e7461670a206966207461673d3d31207468656e200a200970616c2870616c735b325d290a20656c73650a20206261736570616c28290a20656e640a200a206966207461673e3d313020616e64207461673c3330207468656e0a20206c6f63616c20616e696d7365743d616e696d736574735b7461675c31305d0a20206c6f63616c206e")
    (hex 18688 "616d653d616e696d7365746e616d65735b7461672531302b315d0a20206c6f63616c20616e696d3d616e696d7365745b6e616d655d0a0920616e696d3a646f647261772870726f70732e616e696d742c63782c63792c63787363616c652c63797363616c652c63666c6970782c63666c6970792c6364742c72290a090972657475726e2066616c73650a09656c73656966207461673d3d3330207468656e0a092063616d6572612836342d63782c2d6379290a0920647261776d656e7528290a092063616d65726128290a092072657475726e2066616c73650a09656c73656966207461673d3d3331207468656e0a092063616d657261282d63782c2d637929")
    (hex 18944 "0a0920647261776c6561646572626f61726428290a092063616d65726128290a092072657475726e2066616c73650a20656e640a0a2072657475726e20747275650a656e640a0a66756e6374696f6e2064726177636f6e6669726d28290a207265637466696c6c28302c35302c3132382c37372c33290a2072656374282d312c35302c3132382c37372c37290a20637072696e7428636f6e6669726d70726f6d70742c35362c36290a206c6f63616c2073656c636f6c3d6672616d6525383c3420616e642037206f7220360a20707072696e742822794553222c35302c36372c636f6e6669726d783d3d3020616e642073656c636f6c206f722035290a207070")
    (hex 19200 "72696e7428226e4f222c2036392c36372c636f6e6669726d783d3d3120616e642073656c636f6c206f722035290a656e640a0a66756e6374696f6e20757064617465636f6e6669726d28290a2069662862746e7028e2ac85efb88f2929636f6e6669726d783d300a2069662862746e7028e29ea1efb88f2929636f6e6669726d783d310a2069662062746e7028e29d8e296f722062746e7028f09f85beefb88f29207468656e0a2020636f6e6669726d70726f6d70743d6e696c0a2020696620636f6e6669726d783d3d30207468656e0a202020636f6e6669726d666e28290a2020656e640a2020636f6e6669726d666e3d6e696c0a20656e640a656e640a2d")
    (hex 19456 "2d3e380a2d2d20726f7574696e65730a0a66756e6374696f6e2066616465696e28290a2066616465706978656c733d7b7d0a20666f7220693d302c363320646f0a202073736574286925382c695c382c30290a20206164642866616465706978656c732c69290a20656e640a20666164653d22696e220a656e640a0a66756e6374696f6e20647261776661646528290a20696620666164653d3d22696e22207468656e0a202070616c7428302c66616c7365292070616c7428312c74727565290a2020666f7220693d302c32353520646f0a20202073707228302c692531362a382c695c31362a38290a2020656e640a20206966282366616465706978656c73")
    (hex 19712 "3d3d3029666164653d6e696c0a20656e640a656e640a0a66756e6374696f6e207570646174656661646528290a20696620666164653d3d22696e22207468656e0a2020666f72206b3d312c3220646f0a2020206c6f63616c206a3d726e642866616465706978656c73290a20202064656c2866616465706978656c732c6a290a20200973736574286a25382c6a5c382c31290a0920656e640a09656e640a656e640a0a66756e6374696f6e20707072696e74287478742c782c792c63290a20666f72206f783d2d312c3120646f0a2020666f72206f793d2d312c3120646f0a2020207072696e74287478742c782b6f782c792b6f792c31290a2020656e640a20")
    (hex 19968 "656e640a207072696e74287478742c782c792c63206f722036290a656e640a0a66756e6374696f6e20637072696e74287478742c792c63290a20707072696e74287478742c36352d237478742a322c792c63290a656e640a0a66756e6374696f6e206d7072696e74287478742c792c69290a20637072696e74287478742c792c6d656e75693d3d6920616e64206672616d6525383c3420616e64206e6f742069737472616e736974696f6e20616e64206e6f7420636f6e6669726d70726f6d707420616e642037206f722036290a656e640a0a66756e6374696f6e206261736570616c28290a2070616c28290a2070616c2870616c735b315d2c31290a09706f")
    (hex 20224 "6b65283078356632652c31290a656e640a0a66756e6374696f6e207472616e736974696f6e285f616e696d2c5f646f6e65616e696d2c5f646f6e65666e290a20616e696d2c646f6e65616e696d2c646f6e65666e3d5f616e696d2c5f646f6e65616e696d2c5f646f6e65666e0a20616e696d742c69737472616e736974696f6e3d302c747275650a656e64200a0a66756e6374696f6e206765746d6f6465616e696d736574287261636574797065290a206c6f63616c206d6f64656e616d653d7261636574797065616e696d735b72616365747970655d0a2072657475726e207b0a20207072653d616e696d735b6d6f64656e616d652e2e22707265225d2c0a")
    (hex 20480 "20205f696e3d616e696d735b6d6f64656e616d652e2e22696e225d2c0a202069646c653d616e696d735b6d6f64656e616d652e2e2269646c65225d2c0a20206f75743d616e696d735b6d6f64656e616d652e2e226f7574225d0a207d200a656e640a0a66756e6374696f6e206d616b6572616e646f6d726f7374657228742c6e290a2072657475726e2072616e646f6d6e756d732831342c37290a656e640a0a66756e6374696f6e2072616e646f6d6e756d7328742c6e290a206c6f63616c20616c6c6e756d733d7b7d0a20666f7220693d312c7420646f0a202061646428616c6c6e756d732c69290a20656e640a206c6f63616c20726573756c743d7b7d0a")
    (hex 20736 "20666f7220693d312c6e206f72207420646f0a202061646428726573756c742c64656c28616c6c6e756d732c726e6428616c6c6e756d732929290a20656e640a2072657475726e20726573756c740a656e640a0a66756e6374696f6e20736f72742861727261792c636f6d70666e290a20666f7220693d322c23617272617920646f0a20206c6f63616c20632c6a3d61727261795b695d2c690a20207768696c65206a3e3120616e6420636f6d70666e2861727261795b6a2d315d2c632920646f0a20202061727261795b6a5d3d61727261795b6a2d315d0a2020206a2d3d310a2020656e640a202061727261795b6a5d3d630a20656e640a656e640a0a6675")
    (hex 20992 "6e6374696f6e20636f6e6669726d2870726f6d70742c666e290a20636f6e6669726d70726f6d70743d70726f6d70740a20636f6e6669726d666e3d666e0a20636f6e6669726d783d310a656e640a0a2d2d3e380a2d2d206d656e750a0a66756e6374696f6e206472617767616d656e616d6528290a207265637466696c6c2832302c362c3130352c33372c30290a207072696e7428225c5e706d4f542753222c34342c31302c37290a207072696e7428225c5e706752414e442070524958222c32342c32352c37290a656e640a0a6d656e755f747970652c6d656e755f6469662c6d656e755f6c6170732c6d656e755f747261636b2c6d656e755f7374617274")
    (hex 21248 "2c6d656e755f746f75725f73746172742c6d656e755f746f75725f717569743d312c322c332c342c352c362c370a0a66756e6374696f6e206765746d656e756974656d7328290a206c6f63616c206974656d733d7b6d656e755f747970657d0a2069662072616365747970657e3d747970655f70726163207468656e0a2020616464286974656d732c6d656e755f646966290a2020616464286974656d732c6d656e755f6c617073290a20656e640a2069662072616365747970653d3d747970655f746f7572207468656e0a2020696620746f75722e747261636b6e756d3d3d30206f7220746f75722e747261636b6e756d3e23746f75722e747261636b7320")
    (hex 21504 "7468656e0a202009616464286974656d732c6d656e755f746f75725f7374617274290a2020656c73650a202020616464286974656d732c6d656e755f746f75725f71756974290a202020696620746f75722e747261636b6e756d3e3d3120616e6420746f75722e747261636b6e756d3c3d23747261636b6e616d6573207468656e0a20202020616464286974656d732c6d656e755f737461727429200a202020656e640a2020656e640a20656c73650a2020616464286974656d732c6d656e755f747261636b290a2020616464286974656d732c6d656e755f737461727429200a20656e640a2072657475726e206974656d730a656e640a0a66756e6374696f")
    (hex 21760 "6e20647261776d656e7528290a206c6f63616c206974656d733d6765746d656e756974656d7328290a206c6f63616c20796f6666733d28352d236974656d73292a330a2070616c742831322c66616c7365290a206966206e6f742069737472616e736974696f6e20616e64206e6f7420636f6e6669726d70726f6d7074207468656e0a09207373707228382c302c382c382c302c6d656e75792a382d322b796f6666732c3132382c39290a09656e640a20666f7220692c6974656d20696e20697061697273286974656d732920646f0a20206c6f63616c207478742c6172726f77733d22222c66616c73650a2020696620202020206974656d3d3d6d656e755f")
    (hex 22016 "7479706520207468656e207478743d72616365747970656e616d65735b72616365747970655d2020202020202020206172726f77733d747275650a2020656c73656966206974656d3d3d6d656e755f6469662020207468656e207478743d22644946464943554c54593a20222e2e6469666e616d65735b6469665d2020206172726f77733d747275650a2020656c73656966206974656d3d3d6d656e755f6c61707320207468656e207478743d226c4150533a20222e2e6c61706f7074696f6e735b6c61706f7074696f6e5d206172726f77733d747275650a2020656c73656966206974656d3d3d6d656e755f747261636b207468656e207478743d22745241")
    (hex 22272 "434b3a20222e2e747261636b6e616d65735b747261636b6e756d5d206172726f77733d747275650a2020656c73656966206974656d3d3d6d656e755f7374617274207468656e207478743d2221212072414345202121220a2020656c73656966206974656d3d3d6d656e755f746f75725f7374617274207468656e207478743d226e4557206348414d50494f4e53484950220a2020656c73656966206974656d3d3d6d656e755f746f75725f7175697420207468656e207478743d2271554954206348414d50494f4e53484950220a0920656e640a09206c6f63616c20793d28692d31292a382b796f6666730a20206d7072696e74287478742c792c692d3129")
    (hex 22528 "202020200a20206966206172726f7773207468656e0a202020737072283131342c362c792d312c312c312c74727565290a202020737072283131342c3131342c792d31290a2020656e640a20656e640a656e640a0a66756e6374696f6e207570646174656d656e7528290a202d2d2075702f646f776e206172726f77730a2069662862746e7028e2ac86efb88f29296d656e75692d3d310a2069662862746e7028e2ac87efb88f29296d656e75692b3d310a0a202d2d2066696e642063757272656e74206d656e75206974656d0a206c6f63616c206974656d733d6765746d656e756974656d7328290a206d656e75693d6d696428302c236974656d732d312c")
    (hex 22784 "6d656e7569290a206c6f63616c206974656d3d6974656d735b6d656e75692b315d0a0a202d2d206c6566742f7269676874206172726f77730a206c6f63616c20643d300a2069662862746e7028e2ac85efb88f2929642d3d310a2069662862746e7028e29ea1efb88f2929642b3d310a0a206966206974656d3d3d6d656e755f7479706520616e6420647e3d30207468656e20200a202069662072616365747970652b643e3d3120616e642072616365747970652b643c3d2372616365747970656e616d6573207468656e0a0909096c6f63616c2070726576747970653d72616365747970650a09090972616365747970652b3d640a0909096c6f63616c2061")
    (hex 23040 "6e696d7365742c707265767365743d6765746d6f6465616e696d736574287261636574797065292c6765746d6f6465616e696d736574287072657674797065290a090909616e696d736574733d7b616e696d7365742c707265767365747d0a0909096c6f63616c20616e696d3d643c3020616e6420616e696d735b227472616e6c656674225d206f7220616e696d735b227472616e7269676874225d0a0909097472616e736974696f6e28616e696d2c616e696d735b2269646c65225d290a2020656e640a20656e640a206966286974656d3d3d6d656e755f646966296469662b3d640a206966286974656d3d3d6d656e755f6c617073296c61706f7074696f")
    (hex 23296 "6e2b3d640a206966286974656d3d3d6d656e755f747261636b29747261636b6e756d2b3d640a206469663d6d696428312c236469666e616d65732c646966290a206c61706f7074696f6e3d6d696428312c236c61706f7074696f6e732c6c61706f7074696f6e290a20747261636b6e756d3d6d696428312c23747261636b6e616d65732c747261636b6e756d290a200a20647365742831302c7261636574797065290a20647365742831312c646966290a20647365742831322c747261636b6e756d290a20647365742831332c6c61706f7074696f6e290a0a202d2d20627574746f6e730a2069662062746e7028e29d8e296f722062746e7028f09f85beefb8")
    (hex 23552 "8f29207468656e0a20206966286974656d3d3d6d656e755f73746172742972756e67616d652866616c7365290a20206966286974656d3d3d6d656e755f746f75725f7374617274296e6577746f75726e616d656e7428290a20206966286974656d3d3d6d656e755f746f75725f7175697429636f6e6669726d282271554954206348414d50494f4e534849503f222c71756974746f75726e616d656e74290a20656e640a200a202d2d20616e696d617465206d656e7520686967686c696768740a206966286d656e75797e3d6d656e7569296d656e75792b3d73676e286d656e75692d6d656e7579292f340a0a202d2d2064656d6f20636f756e746572200a20")
    (hex 23808 "6966282862746e28292630783366297e3d302964656d6f6374723d6d61782864656d6f6374722c31383030290a2064656d6f6374722d3d310a2069662064656d6f6374723c3d30207468656e200a202064656d6f3d747275650a090972616365747970652c6469662c6c61706f7074696f6e2c747261636b6e756d3d312c322c312c726e642823747261636b6e616d6573295c312b310a200972756e67616d65287472756529200a20656e640a656e640a0a2d2d3e380a2d2d20646562756767696e670a0a6c696e65732c733d7b7d2c302066756e6374696f6e2064616464286e2c762c692c70297768696c6520703e3120616e64206c696e65735b702d315d")
    (hex 24064 "2e693d3d6920616e642074797065286c696e65735b702d315d2e6e293d3d74797065286e29616e64206c696e65735b702d315d2e6e3e6e20646f20702d3d3120656e6420616464286c696e65732c7b6e3d6e2c763d762c783d747970652876293d3d227461626c6522616e64222b226f722220222c693d697d2c7029656e640a66756e6374696f6e2064657870286c2c70296966206c2e783d3d222b227468656e20666f72206e2c7620696e207061697273286c2e7629646f20702b3d312064616464286e2c762c6c2e692e2e2220222c7029656e64206c2e783d222d22656c73656966206c2e783d3d222d227468656e207768696c6520703c236c696e6573")
    (hex 24320 "20616e6420236c696e65735b702b315d2e693e236c696e65735b705d2e6920646f2064656c69286c696e65732c702b3129656e64096c2e783d222b2220656e6420656e640a66756e6374696f6e2064696e7028296c6f63616c20782c792c622c773d73746174283332292c73746174283333292c73746174283334292c73746174283336296c696e6528782c792c782c792b322c31302969662062746e7028e29d8e29207468656e206c6f63616c20693d28792d3130295c362b31206c6f63616c20703d732b69206c6f63616c206c3d6c696e65735b705d6966206c20616e6428782d3130295c343d3d236c2e69207468656e2064657870286c2c7029656e64")
    (hex 24576 "20656e6420733d6d6178286d696e28732d73746174283336292c236c696e65732d3138292c302920656e640a66756e6374696f6e2064756928297768696c65207472756520646f207265637466696c6c2831302c31302c3131382c3131382c3129666f7220693d312c313820646f206c6f63616c206c3d6c696e65735b692b735d6966206c207468656e207072696e742873756228225c6663222e2e6c2e692e2e6c2e782e2e6c2e6e2e2e223a5c6637222e2e746f737472286c2e76292c312c3331292c31302c28692d31292a362b31302c3729656e6420656e642064696e702829666c69702829656e6420656e640a66756e6374696f6e2064696e73702876")
    (hex 24832 "2964616464282276616c7565222c762c22222c236c696e65732b3129706f6b65283078356632642c3329637572736f72282970616c2829636c697028296475692829656e640a0a2d2d3e380a2d2d20746f75726e616d656e740a0a66756e6374696f6e206e6577746f75726e616d656e7428290a20746f75722e747261636b733d72616e646f6d6e756d732823747261636b6e616d6573290a20746f75722e747261636b6e756d3d310a20746f75722e726f737465723d6d616b6572616e646f6d726f7374657228290a20746f75722e706c617965727074733d300a20746f75722e7074733d7b7d0a20666f7220693d312c3720646f0a202061646428746f75")
    (hex 25088 "722e7074732c30290a20656e640a2073617665746f75726e616d656e7428290a207570646174656c6561646572626f61726428290a206d656e75693d340a200a202d2d20746f646f3a20616e696d6174696f6e0a656e640a0a66756e6374696f6e2071756974746f75726e616d656e7428290a0a202d2d20746f646f3a20636f6e6669726d6174696f6e2070726f6d707420696620746f75726e616d656e742072756e6e696e670a20746f75722e747261636b6e756d3d300a2073617665746f75726e616d656e7428290a656e640a0a66756e6374696f6e206c6f6164746f75726e616d656e7428290a20746f75723d7b0a2020747261636b6e756d3d646765")
    (hex 25344 "74283430292c0a2020747261636b733d7b7d2c0a2020726f737465723d7b7d2c0a20207074733d7b7d2c0a2020706c617965727074733d300a207d0a20696620746f75722e747261636b6e756d3e30207468656e0a2020666f7220693d312c23747261636b6e616d657320646f0a20202061646428746f75722e747261636b732c646765742834302b6929290a2020656e640a2020666f7220693d302c3620646f0a20202061646428746f75722e726f737465722c646765742835302b6929290a20202061646428746f75722e7074732c646765742835372b6929290a2020656e640a2020746f75722e706c617965727074733d64676574283439290a202075")
    (hex 25600 "70646174656c6561646572626f6172642829200a20656e64200a656e640a0a66756e6374696f6e2073617665746f75726e616d656e7428290a20647365742834302c746f75722e747261636b6e756d290a20696620746f75722e747261636b6e756d3e30207468656e0a2020666f7220693d312c23747261636b6e616d657320646f0a202020647365742834302b692c746f75722e747261636b735b695d290a2020656e640a2020666f7220693d302c3620646f0a202020647365742835302b692c746f75722e726f737465725b692b315d290a202020647365742835372b692c746f75722e7074735b692b315d290a2020656e640a2020647365742834392c")
    (hex 25856 "746f75722e706c61796572707473290a20656e64200a656e640a0a66756e6374696f6e207570646174656c6561646572626f61726428290a206c6561646572626f6172643d7b7d0a20666f7220692c63617220696e2069706169727328746f75722e726f737465722920646f20200a2020616464286c6561646572626f6172642c0a2020097b0a202009206e616d653d61696361726e616d65735b6361725d2c0a20200920703d616963617270616c735b6361725d2c0a202009207074733d746f75722e7074735b695d0a2020097d290a20656e640a20616464286c6561646572626f6172642c7b0a2009096e616d653d22704c41594552222c0a2009097074")
    (hex 26112 "733d746f75722e706c617965727074732c0a2009096973706c617965723d747275650a20097d290a20736f7274286c6561646572626f6172642c66756e6374696f6e28612c622972657475726e20612e7074733c622e70747320656e64290a656e640a0a66756e6374696f6e20647261776c6561646572626f61726428290a207072696e742822647269766572222c302c312c35290a207072696e742822706f696e7473222c35382c312c35290a20696628746f75722e747261636b6e756d3d3d302972657475726e0a20666f7220692c6520696e20697061697273286c6561646572626f6172642920646f0a20206c6f63616c20792c636f6c3d692a362b32")
    (hex 26368 "2c652e6973706c6179657220616e642037206f7220360a202070616c28290a202070616c7428302c66616c7365290a202070616c742831322c74727565290a2020696628652e702970616c28652e702c30290a202073707228382c302c79290a202070616c28290a09097072696e7428652e6e616d652c31302c792c636f6c290a09096c6f63616c207478743d746f73747228652e7074732909090a09097072696e74287478742c38322d237478742a342c792c636f6c290a20656e640a200a20696620746f75722e747261636b6e756d3e23746f75722e747261636b73207468656e0a20206966206672616d652533303c3135207468656e0a092020707269")
    (hex 26624 "6e74282266494e414c207354414e44494e4753222c31322c36302c37290a0920656e640a20656c73650a20206c6f63616c20747261636b6e756d3d746f75722e747261636b735b746f75722e747261636b6e756d5d0a20206c6f63616c20747261636b6e616d653d747261636b6e616d65735b747261636b6e756d5d0a20207072696e7428226e4558543a222e2e747261636b6e616d652c2d322c36302c37290a20656e64200a656e640a0a66756e6374696f6e206170706c7972616365726573756c747328290a0a202d2d20706c6179657220706f696e74730a206c6f63616c20706c61796572706f733d64676574283331290a20746f75722e706c617965")
    (hex 26880 "727074732b3d726163657074735b706c61796572706f735d0a0a202d2d2061692063617220706f696e74730a20666f7220693d312c3720646f0a20206c6f63616c20706f733d646765742833312b69290a2020746f75722e7074735b695d2b3d726163657074735b706f735d0a20656e640a200a202d2d20616476616e636520746f206e65787420747261636b200a20746f75722e747261636b6e756d2b3d310a20200a2073617665746f75726e616d656e742829200a207570646174656c6561646572626f6172642829200a656e640a0a2d2d3e380a2d2d20747261636b730a747261636b646174613d7b0a2d2d206272616e64732068617463680a22c2b2")
    (hex 27136 "e281b8c2b366696ec2b3285c303dc2b25c30e383a3e281b8c2b9e1b6a0c2b95c72325c30e296a1e383abc2b9e1b589235c305c225c30c2b9e1b69c5c72e28198e383a85c30645c30e28198e383a85c30585c30e281b8e383955c30465c30e296a1e281985c30e281985c30e296a1e281985c30e380815c30e296a1e281985c30245c30e296a1e281985c302a5c30e3808de3808d5c302a5c30e3808de281985c30e281b55c30e38082e1b6a05c30555c30e28199e1b6a05c30645c30e281b4e3808dc2b3365c30e1b5875c305c30625c30c2b370646be281b7e281985c30303033c2b95c305c6ec2b9e1b589c2b9e1b69ce3829b5c30e1b6a0095c3046e383a0")
    (hex 27392 "e28198e281985c30c2b9e281b85c30e3808d5c3053e281b45c30e383abc2b9e1b69cc2b9e381ace281985c30c2b9e2979de2979de281985c304fc2b95c305c30e383a3e281b5c2b2e38280e382b9285c30725c30c2b95c72c2b95c72c2b2e383a0e28198e281b4e29780e3828d5c30415c30e3808ce3828d5c30465c30e29780e382a65c30485c30e280a25c305c30f09f90b15c30c2b3647264e281b72d5c305fe3808c5c30e28096e383ade28198c2b9e1b69cc2b9e3838ce3829b5c3048e281b8c2b2e38395e281985c6e5c30c2b9e383a5e2979de281985c30e1b587e2979de2979d5c30e3829be280a25c30c2b9e383a8e2979d285c3072e383acc2b2e1")
    (hex 27648 "b6a0e1b589c2b9e1b589c2b9e3838ce281985c3069e383a5e2979de281b8c2b95c72c2b9e383a0e1b589e3808ce383a85c30e1b6a05c30e296a1e383a85c30e281b85c30c2a5e281b85c30e281995c30c2a5e281b85c30205c30c2a5e281b85c302d5c30c2a5e281b85c303a5c30c2a5e383b35c30e3818a5c30c2a5e383b35c30e381975c30e38081325c30e381845c30e38081325c30e299a55c305c6e3c5c306e5c30e296a1e3808d5c30e382865c30e296a1e3808de2979ce382865c30e296a1e3808de383a5e382865c30c2b37375725c72285c3021e383a7e2979dc2b9e1b69ce281985c3029e383a7e2979d23c2b9e1b589e1b6a05c30c2b9e2979ce2")
    (hex 27904 "979de281985c30e382bfe38383e2979d5c30e281b8c2b95c72c2b923e3808d5c307a095c6ec2b9e1b6a0c2b9e1b6a0c2b2e383a8e1b6a0e3829b5c3040c2b2e383a8e1b6a05c6e5c3041c2b35c30c2b2e383a8e1b6a0235c3042e3808dc2b2e383a8e1b6a05c6e5c304ee3829be383a3e281b5c2b2e383a8e1b6a0e281985c3040c2b2e383a8e1b6a0e281985c304ce383ad5c6ec2b2e383a8e1b6a0e281985c3042e383a9c2b2e383a8e1b6a0e1b6a05c3040c2b2e383a8e1b6a05c6ee29780e1b6a05c30e1b6a05c30e29780e1b6a05c30e297805c30e3808ce1b6a05c30e380825c30e29780e1b6a05c30245c30e280a25c305c30e382b95c30c2a5e281b7")
    (hex 28160 "5c30e28c825c30c2a5e281b75c30e296a55c30c2a5e281b75c30e383ab5c30c2a5e281b75c30c2b2c2b9c2a5e383b35c30c2b2c2b9c2b3686177c2b3e281985c3075e1b5895c30e383a0c2b95c72c2b9e1b589c2b2e38395e1b6a0e281985c3047e1b5895c305c30e383abc2b3e38395e1b6a0e3838c325c3060c2b95c72c2b2e383a0e1b6a0c2b9e28199e383a85c30525c30c2b3777374e281b8e281985c3041e1b6a05c30c2b2e383a8e1b6a0e3808d5c3043c2b35c30e38082c2b2e383a8e1b6a0e281985c3043e281b65c30303032c2b2e383a8e28198e281985c3042e38395c2b2e383a8e28198235c3043e281b75c305c30c2b2e383a8e1b6a0e28198")
    (hex 28416 "5c3051e281b75c30c2b9e1b69cc2b2e383a8e1b6a0e1b6a05c304fe1b5875c30e1b587e383a0e1b69cc2b2e3839be296a0285c304ec2a5e383ad5c6ec2b2e383a0e296a0c2b2c2a5e281b85c30e3818d5c30c2a5e281b85c30e381a65c30e281b47374726c09e1b6a05c3059e383aae2979de28198c2b95c72c2b2e383a8e3808de1b6a05c304be383aae2979d5c30e1b69cc2b2e383a8e281983c5c3042e29780c2b2e1b6a0e383a85c6e5c304e09e383a3e281b5c2b2e383a8e1b6a05c6e5c3042e383adc2b2e383abe1b69ce281985c304ce383a8e28198c2b9e383a4e281985c3050c2b9e1b6a0c2b9e3839e285c3043095c30e1b589c2b9e3839ee28198")
    (hex 28672 "5c307be281b45c305c30e281b8c2b9e1b69cc2b9e1b69cc2b9e382b9e281b4e280a25c305c30675c30c2a5e281b85c304b5c30c2a5e383b25c304b5c30e28198e383955c30e381a35c30c2b3656e64c2b23c5c305be281b45c30e383a2e281b5c2b9e1b6a0c2b9e382b9e3808d5c302fc2b95c305c30e383a8e281b5c2b95c72e281b4e3808ce383845c303e5c30e3808ce383845c30445c30e296a1e383845c304a5c30e29780e383845c30505c30e1b69ce281b4222c0a2d2d20686f636b656e6865696d0a22c2b2e281b7e281b666696e697368c2b9785c30303034e383abc2b95c72c2b95c72e296aee281b7e383a05c305c305c30e281b7e383a05c30e2")
    (hex 28928 "81985c30e281b7e383a05c30285c30c2b3e38395e383a7235c30e281b7e383a05c303c5c30e281b7e383a05c30505c30e1b5875c305c303030325c30e38082e1b69c5c30275c30c2b3e296aec2b3335c30e297805c6e5c30e281985c3020e281b7e383a5405c30c2b3e296aec2b3475c30e281b7e383a05c30645c30e281b8e383a05c30785c30c2b3e296aec2b35b5c30c2b3e296aec2b36f5c30e281b46e6f7264e1b589215c30e3808de1b69c5c30e1b69cc2b9e1b69ce1b69c5c3020c2b9e1b69ce281985c30e281b4e383b2e1b6a05c3058e281b5c2b2e1b6a05c72c2b2e3839528e281985c3070c2b95c72c2b95c72c2b2e383a0e28198e281b85c3044")
    (hex 29184 "e383a5c2b2e383a8e1b6a0e281b45c3040c2b2e383abe1b69ce281985c304ce383b25c6ec2b2e383a6e296aee281985c3050c2b9e1b6a0c2b2e383a8e1b6a0645c3041c2b95c30c2b2e383abe1b589645c3051c2b25c30c2b95c72c2b2e383ace1b5895c6e5c304ce383a3e281b5c2b2e383ade1b69ce281b85c3040c2b2e383abe1b69ce3829b5c3048e28198c2b2e383b2e3829be1b589e281b7e383a05c305c6e5c30e281b7e383a05c30e3829b5c30c2b3e296aec2b3e1b5875c30e3808de383845c30e3829b5c30e3808de383845c30235c30e281b7e383a05c303030325c30c2a5e281b85c302a5c30c2a5e281b85c303030325c30c2a5e281b85c303a")
    (hex 29440 "5c30e280a25c305c306e5c3020e38383e383a7e3818d5c3020e38383e383a7e382ad5c30e3808de383a05c30e281b4c2b9e280a25c305c306dc2b9e281b5636c61726be1b6a0e1b69c5c3047e281985c30e281b7e383a0c2b2e382b928e281b85c3044e3838cc2b2e382b9e3808de1b5895c3047e38392e2979d5c30e383abc2b2e382afe3829be281985c3058e281b8c2b9e1b69cc2b2e38384e3829b2d5c3051c2b25c30c2b95c72c2b2e1b69ce38384285c3041c2b95c30c2b2e1b69ce38384285c3041c2b95c30c2b2e1b69ce38384285c3041c2b95c30c2b2e1b69ce38384285c3041c2b95c30c2b3e383a9e1b69ce3838c5c6e5c304ce383a3e281b5c2")
    (hex 29696 "b9e1b69ce281b85c3040c2b9e383ad5c6e5c305c5ce383b2e281b8c2b2e1b6a05c72c2b2e383abe1b69ce281985c3040c2b2e383abe1b69ce296a05c30525c6ec2b95c72c2b2e383a2e1b69ce1b6a05c30565c6ee383a8c2b2e1b6a05c72c2b2e383a2e1b69ce296b6e281b7e38381c2b2e1b6a05c30e28199e3808d5c30205c30e281b7e383a0c2b9285c30e281b7e383a0c2b23c5c30e281b7e383a0c2b2505c30e281b7e383a0c2b2645c30e281b7e383a0c2b2785c3020e383a8e2979c645c30e281b7e383a0c2b2f09f98905c30e281b7e383a0c2b2e3818d5c30e281b7e383a0c2b2e381b25c30e281b7e383a0c2b2e381a35c3020e383a8e2979ce381")
    (hex 29952 "b25c30e296aee383aa5c30e381b55c3020e383a8e2979ce382865c3020e383a8e2979ce381a35c3020e383a8e2979ce382ad5c30e280a25c305c30e1b589c2b9e281b8e383a4c2b2e281b4c2b920e38383e383a7e3829cc2b9e3808ce383ac5c30303035c2b9e29780e383ac5c303cc2b920e38383e383a744c2b9c2b36f7374e296aee1b69c5c3057e3808c5c30e1b6a0e382b9c2b9e1b69cc2b3e382b9e3828de1b69c5c6e5c304609e382b9c2b2e3828de1b69ce281b85c3047e38395e2979de383ade382b9c2b3e1b69ce3828de296a15c6e5c30c2b95c725c30e281985c3047e281b65c305c30e383abc2b3e382b9e1b69ce296a1e1b6a05c3051e281b4")
    (hex 30208 "5c30c2b95c72c2b2e383a9e1b69c325c3052e281b4c2b9e1b69cc2b2e383a9e1b69c5c6e5c305c5ce383a3e281b5c2b95c72c2b2e383abe1b69ce281b55c3040c2b2e1b69ce383ab5c6e5c304ce383b2e281b8c2b2e383abe1b69c325c3042e38383c2b2e383abe1b69c465c304ee281b4e383b2e281b8c2b2e383abe1b69c5c6e5c304e5c30e383a3e281b5c2b2e383ab5c6ee281b55c3040c2b2e383ad5c6e5c6e5c304ce383b2e281b8c2b2e383abe1b69ce281985c3064e383a0c2b9e1b69cc2b2e38395e1b69ce281b7e281b8e382a65c30e1b5895c30e281b8e382a65c30e3808c5c30e280a25c305c30e2978b5c30e280a25c305c30c2a5c2b9e296a0")
    (hex 30464 "e3839e5c302d5c30e296aee383a05c303030305c30e296aee3838c5c302a5c30e281b573656e6e6109e281b85c304de3838ee2979de38395e1b69cc2b2e3838de1b5895c6e5c304ce3838ce280a2c2b2e3838ae38082e296a15c3069e281985c30e29780c2b95c72c2b2e382a6e3829b5c6e5c304ce383a2e281b8c2b2e3838ae29780e281985c3045e383a5e2979de383b2c2b2e383a25c6e325c3042e38383c2b2e383ad5c6e325c304209c2b2e383ad5c6e325c3042e1b69cc2b2e383ad5c6e325c3042e383afc2b2e383ad5c6ec2b2e281b8e382bfc2b9e3808c5c30e296aee383955c302a5c30e281b461676970e281b7e281b55c304ce383a3e281b5c2")
    (hex 30720 "b9e383ade281b55c3040c2b9e383ade281b55c304ce383b2e281b8c2b9e383ade1b6a05c3040c2b9e383abe1b6a05c3070c2b2e1b6a05c72c2b2e1b6a05c72c2b9e3839be3829b5c30303035e1b69c5c30e3838cc2b9e1b69cc2b9e1b69c375c305c30e296a0e280a25c305c30e281b75c30e296a0e281985c305c225c30e296a0c2a55c30235c30e296aee3829c5c30235c30e296a0255c30235c30e296aee1b5895c30e296a15c30e296a0e1b589e38383e296a15c30e281b7e382b95c303e5c3009e1b589c2b24b5c3009e1b589c2b25f5c3009e1b589c2b2735c3020e38383e383a75c225c3020e281b6e383a75c225c30e3808de382835c30445c30e380")
    (hex 30976 "8de382885c304c5c30e281b7e382b95c305a5c30e296a1e382b95c30785c30e281b573616368735c6e235c30e296a0e383a0e2979dc2b95c72e1b6a05c3009e383a8e2979de1b6a0e1b5895c30c2b2e281b7e1b5875c30c2b3e383aae2979de383a35c6e5c305c30e1b5875c30c2b9e1b69c5c30e1b69c5c305c30e3808d5c3043e296a05c305c30c2b9e3828d095c3042e383a3c2b9e3828d235c3047e1b6a05c305c30e383abc2b9e3828de1b58909e1b589c2b2e281b55c30c2b3e28198c2b2e281b55c30e29780e3808d5c30205c30e29780e3808d5c30265c30e3829c3c5c303030375c30e296aee281985c30e380825c30e296aee3808d5c30e380825c")
    (hex 31232 "30e296a1e281985c303a5c30e3808de3829b5c30645c30e281b8e382a85c30695c30e281b7e382a65c30785c30e281b7e382a65c30f09f98905c30e281b7e383845c30e3818a5c30e3808de3828d5c30e381a65c30c2b9c2b2222c0a2d2d206175746f64726f6d6f206e617a696f6e616c65206d6f6e7a610a22c2b2e281b8c2b366696e5c6e285c303ce383a3e281b4c2b9e1b6a0c2b9e1b69c5c6e5c30c2b9c2b35c302d5c305c30285c305c303030325c3070c2b2e1b6a05c72c2b95c72c2b9e383a0e281985c305c30e3829b5c3040c2b9e383afe3829b5c3070c2b9e1b6a0c2b9e1b6a0c2b9e383a05c6e5c3020c2b9e1b69c5c6e5c30e281b8e1b6a026")
    (hex 31488 "c2b3e383a9c2b3285c3009e1b69cc2b9c2b35c30e296aee1b69c5c30e380815c30e297805c6e5c302a5c30e3808ce1b6a05c302a5c30e3808c5c6e5c30255c30e29780e1b6a05c30255c30e38081e281b85c303030345c30e281b8e383adc2b9e382865c30e38082e281b85c30e299a55c30c2b3e1b69ce281b4e3818d5c30e1b5875c305c30e288a75c30c2a5e281b6e2979de382ad5c30c2a5e281b6e2979de381a35c30c2a5e281b6e2979de382865c30095c6e5c30e383a65c30e296ae095c30e383925c30e28199e383b25c3009c2b920e383a7e383a7e3839f5c3020e383a7e383a7e383af5c3020e383a7e383a7c2b3c2b95c6e5c6e5c30e281b4c2b9")
    (hex 31744 "09e281b8c2b2415c3009e281b8c2b2555c3009e281b8c2b2695c305c6ee281b8c2b27d5c3020e383a7e383a7e1b6a0c2b9e3808de383ab5c30e1b589c2b9e28199e383afe383a3285c30c2b3e383a9c2b33c5c30c2b3e383a9c2b3505c30c2b3e383a9c2b3645c30c2b3e383a9c2b3785c30e281b8e383ab5c30e28198c2b9c2b3e383a2c2b35c305c30e296aee383a95c30e380815c30e296aee383a25c30e380815c30e296a0e383a8e383a5e380815c3009726574746966696c6fc2b35c6e5c30e281b5e3829c5c30e383a0e1b69c5c3045e38388e2979de383a0c2b9e38082285c304ce383afe281b6c2b9e3808de281b7e28199e281985c30e297805c30")
    (hex 32000 "e28199e281995c30e280a25c30e28199e296a05c30215c30e281b7e383955c30235c30e281b7e3838c5c30e281b85c30e296aee296a05c303c5c30e281b7e383a05c303030375c30e281b862696173736f6e6fe1b6a0e1b6a05c3069e281b65c30e281b5c2b95c72c2b9e1b589e1b6a05c3050c2b95c72c2b2e1b587e383a8e281b55c3044e383a3c2b2e1b587e383a8e281b55c3040c2b2e1b587e383a9e281b55c3044e383afc2b2e1b587e383a9e1b6a05c3040c2b2e1b587e383a9e3829b5c3041e281b45c30c2b9e383a9e3829b5c3051e281b55c30c2b9e1b69cc2b2e383aae1b69ce3829b5c3051e281b45c30c2b9e1b6a0c2b2e383a0e296a1e28198")
    (hex 32256 "5c3040c2b2e383a25c6ee3808d5c3050c2b95c72c2b2e383aae281b85c6e5c304ce383a3e281b5c2b2e383aa5c6ee281b55c3040c2b2e383aa5c72e281b55c304ce38383e281b8c2b2e383ab5c72235c3050c2b9e1b6a0c2b9e1b69ce281b5e3808de281b65c30e281b55c30e280a25c305c30255c30e280a25c305c30e382a85c30e297805c6e5c307e5c30e297805c6e5c30e299a55c30e281b6726f67676961e281b75c6e5c3044e383abc2b95c725c6e5c30c2b9e38388e2979d5c6e5c30e281b5e280a25c30e383ade281985c3050c2b9e1b69cc2b9e383aa5c6e5c304de383a5e2979de383a3e281b5c2b9e383abe281b55c3040c2b2e383ad5c6e235c")
    (hex 32512 "3054e383aac2b9e1b6a0c2b25c72e383a8e281b509e28198c2b95c725c30e280a25c305c303a5c3009e1b589c2b9245c3020e38383e383a7495c30c2a5e383b25c30555c30e281b56c65736d6fe281b6e3829b5c30515c725c30c2b9e1b589c2b2e3839b5c6ee3829b5c3050c2b9e1b69cc2b2e383a65c6ee281985c3050c2b95c72c2b2e383a65c6e5c6e5c3050c2b9e1b69cc2b9e383a6e281985c3059e296a05c30e1b69cc2b95c72c2b9e383a65c6e5c3048e281b6c2b2e383a6e1b6a0c2b3e28199e383a45c30e296a15c305c6ee1b69cc2b2505c30e297805c6e5c305b5c30097365727261676c696fe1b589285c304ce383a3e281b5c2b2e383a65c6e")
    (hex 32768 "e281b55c3040c2b2e383a9e1b589e281b55c3040c2b2e383ad5c6ee3829b5c3040c2b2e383b2e281b8e3829b5c3041e2979ce2979dc2b2e383b2e28198e281985c3042e281b8c2b2e383b2e1b69ce281985c3042e383a3c2b2e383b2e1b69ce281b55c3040c2b2e383a9e1b589e281b55c3040c2b2e383ade1b69c285c30425c30c2b2e383b2e1b69ce281b55c3040c2b2e383abe1b69ce281b55c3040c2b2e1b587e383ade281985c304ce383a0e281b8c2b25c6ee383a0e281985c3064e383abc2b9e1b69cc2b2e38398e1b69ce281b5e280a25c305c302a5c30e280a25c305c30e296a45c30e280a25c305c30e382855c30e296a1e1b5895c30645c30e297")
    (hex 33024 "80e1b589e2979c645c30e281b6617363617269e28198e1b6a05c305de38398e2979de383a5e28198c2b9e1b69cc2b2e28096e383a05c6e5c30715c6e5c30c2b9e1b589c2b9e1b589c2b2e383b2e297805c6e5c30455c725c30e383abc2b2e383abe297805c6e5c30415c6e5c30c2b9e383a6e1b6a05c3045e38398e2979de38383c2b2e38081e383a62d5c30e3808ce1b69cc2b9e1b6a0e3808d5c3078e281b8c2b95c72c2b95c72c2b9e383abe281b55c304ce383a3e281b5c2b2e383ad5c6ee281b55c3040c2b2e383ad5c6ee281b55c30e1b69ce38383e281b6e281985c3050c2b9e1b6a0c2b9e383aae281985c3040c2b2e1b69ce383a95c6e5c30485c6e")
    (hex 33280 "c2b9e383aae281985c3040c2b2e296aee383a9e281b55c305c5ce383a3e281b5c2b95c72c2b2e383abe1b69ce281b55c3040c2b2e383ad5c6ee281b55c30e1b69ce383b2e281b65c6e5c3050c2b9e1b6a0c2b2e383ade1b69c2d5c30e296aec2b95c72e1b6a05c3044e383acc2b9e1b58920e28199e383b35c30e1b69c5c305c6ee38081c2b93d5c30e28199e383ab5c303030345c30e28199e383abe383a7345c30e280a25c305c30ec9b835c30e280a25c305c30e383865c3009e281985c30505c30c2b3e281985c30505c305c6ee281985c306e5c30e3829ce296a05c307d5c30c2b2e281985c306e5c30e296aee280965c304c5c30e296a0e297805c3048")
    (hex 33536 "5c30e296a05c725c30f09f90b15c30e296aee1b6a05c307c5c30e28199e383b25c306e5c30e28198e1b6a0c2b2e381845c30e3829ce1b6a05c30e381975c30e3829ce1b6a05c30e381bf5c30e29780095c30e381b85c30e3829ce3808d5c30e383815c30e296aee1b69c5c30e382865c30e296a0e1b69ce383a5e382865c3020e38383e383a7e383a25c30e281b7e383a6c2b9e383ac5c30e281b7e383a6c2b909c2b9e281b8e383a6c2b9e38082c2b9e3829ce3808d5c3009c2b9e3829ce3808d5c30e38082c2b9e296aee1b69c5c30e28199c2b9e296aee1b69c5c3009c2b9e3808de281b85c303bc2b95c6e70617261626f6c696361e281b45c6e5c30e281")
    (hex 33792 "98e383a9c2b9e1b69ce3829b5c30455c725c30e383a0c2b2e38398e1b69ce281985c30415c725c30c2b2e38398e1b69ce3829b5c305d5c725c30e383abe281b6c2b9e1b6a0c2b9e3839ee281b4e281b8e383a25c305c305c30c2b2e383a25c305c305c30e28199e281b85c30e281b55c3020e383abe383a7545c30e1b69c5c72222c0a2d2d2073696c76657273746f6e650a22c2b2e1b6a0e281b868616d696c746f6ec2b3e281985c303e5c30e383b2e281b4c2b9e1b69cc2b9e1b69ce3829b5c305c305c6e5c305c225c30c2b95c7209e281b4e3808dc2b25c305c30e281b4e3808dc2b2e281985c30e281b4e3808dc2b2285c30e281b7e383a65c30e1b587")
    (hex 34048 "5c30c2b3e383a65c30e1b5875c30e296aee383a65c30255c30e281b7e383a65c302f5c30c2b3e383a65c302f5c30e1b5875c305c30e3829c5c30e281b56162626579c2b3e1b6a05c3009e1b6a05c30e1b6a0e3829b5c30e28198e383adc2b9e1b5895c6e5c30e2ac87efb88fe383a0e2979de1b6a0e281b4e296a0e383955c30e281985c30e281b7e383a65c30e3808d5c30e296a0e383a85c302f5c30e281b7e383a65c303030315c30e281b46661726dc2b3e1b6a05c305c225c30c2b9e1b589e3808d5c3040c2b9e3829b5c6e5c305c30c2b3e281b7e383a65c305c305c30e281b7e383a65c30275c30c2b3e383a65c30275c30e281b776696c6c616765c2")
    (hex 34304 "b2e281985c3043e3829b5c305c30c2b9e3838c5c6e5c30425c30c2b9e383a05c30e281b46c6f6f70c2b9e3829b5c30c2b3e3838ee2979d5c305c30e281b761696e74726565c2b2e3808d5c303fe383a3e2979d5c30e383ade1b6a0c2b9e1b6a0c2b9e1b6a0e3808d5c3043e383a0e2979d5c30c2b9e3829b5c305c6e77656c6c696e67746f6ee281b72a5c306a5c305c6ec2b2e1b6a05c72c2b9e3829be281b65c30e3829b5c30e383a3e281b5c2b2e1b6a05c72e281b45c305c30e281b65c30e1b5895c30e383ad5c6ee3829b5c30525c30c2b9e1b6a0c2b9e38384255c305c30e3808d5c3040c2b9e3839ee1b6a0e3808ce3839e5c30e3808d5c30e3808de2")
    (hex 34560 "81985c30e380825c30c2a5e383835c30e3829b5c30c2a5e281b65c30e3829b5c30c2b3e3808de281b4245c30e3808ce3839e5c30255c30e280a25c305c303030325c30e29780e3839e5c303e5c3009e1b5895c303f5c30c2b3e1b5895c303f5c30e29780e3839e5c304c5c30e29780e3839e5c305a5c30e3808ce281985c30685c30e3808ce281985c30715c30e38082e1b6a05c307a5c305c6e62726f6f6b6c616e6473c2b2325c30e28199e3839ee2979d5c30c2b9e1b69ce281b85c30c2b25c30e281b6e296aee1b6a05c305c725c305c6ee281985c30e296b65c30c2b2e281985c30e296b65c30e296aee1b6a05c302e5c305c6ee281985c303030325c30")
    (hex 34816 "c2b2e281985c303030325c30e281b8776f6f64636f7465e281b6e3808d5c303fe3808d5c305c30e383a85c6ec2b9e1b6a0c2b9e1b589e281985c30e296b6e3808d5c305c30e383a0c2b95c72e3829b5c305c30e281985c3009e1b6a05c30e281b4465c305c30e3829b5c305c30e3808ce29780e383845c30e1b5875c30e296a0e383955c30e296a15c30e29780e383845c30e380815c30e296aee383845c30215c30e281b7e3838c5c30285c30c2b3e3838c5c30285c30e281b8e3838c5c30415c30c2b2e3838c5c30415c30e281b8e3838c5c30465c30c2b2e3838c5c30465c30e38081e1b6a05c30505c30e281b8e3838c5c305b5c30c2b2e3838c5c305b5c")
    (hex 35072 "30e38081e1b6a05c30f09f90b15c30e3808ce3838c5c307e5c30e296a0e383955c30e2978f5c30e3808de383955c30e2ac85efb88f5c30e29780e3838c5c30e298855c30e29780e3838c5c30e381885c30e29780e3838c5c30e3819d5c30e29780e3838c5c30e381af5c30e38081e1b6a05c30f09f98905c30e296a1e1b6a05c30e381b25c30e28198e1b6a0e383a5e299a55c30e281b5636f707365e281b5e281985c30e280a2e281995c30e28199e1b69cc2b9e1b69ce3829b5c30c2b9c2b95c30e281985c3043c2b95c305c30c2b9e3838ce281985c307ce383a3e281b5c2b2e1b6a0e1b589c2b9e1b589c2b9e3838ce3829b5c3070c2b2e1b6a0e1b589c2")
    (hex 35328 "b2e1b6a0e1b589c2b9e3838ce281b8e281b8e3838c5c30e1b5875c30c2b2e3838c5c30e1b5875c30e281b8e3838c5c30e3808d5c30c2b2e3838c5c30e3808d5c30e281b8e3838c5c30275c30c2b2e3838c5c30275c30e296a1e1b6a05c303030335c30e280a25c305c30695c30e281b76d6167676f7473c2b3e1b6a05c30c2b3e383ade2979d5c30e3808d5c30e281b5e1b5875c30e383abe281985c305c30c2b3e281b8e383a05c302f5c30c2b2e383a05c302f5c30e3808de383a95c305c305c30e281b86265636b65747473e281b4e3829b5c303de383a8e2979de3838ce3829bc2b2e1b6a05c72c2b2e1b6a05c72235c3051e281995c30c2b95c72c2b9e3")
    (hex 35584 "82b9e281b85c30e28198e383a8c2b9e1b589e1b6a05c3055e383a4e2979de383b3c2b2e1b6a0e1b589c2b9e382b9c2b2e3808ce383815c303e5c30e3808ce383815c30465c30e281b668616e676172e281b5e3808d5c305c6e09e28198e3808d5c302e09e383a3e281b5c2b2e1b6a0e1b589e3808d5c304ce383af09c2b2e28198e3838ce3808d5c3062e1b589c2b9e1b589c2b9e383a0e3829b5c305c225c30c2b9e1b69c5c6ee3808de383ab5c30c2a55c30e297805c225c30e380825c30e3808ce3808d5c30285c30e280a25c305c303030335c30e296a1e383955c303030375c30e28199e38395e2979d385c30c2a5e383835c30505c30c2a5e281b65c30")
    (hex 35840 "505c30e3808ce1b6a05c305d5c30e29780e281985c306d5c30e281b573746f7765c2b23c5c3051e1b5895c30c2b9e1b589c2b9e382a65c6e5c30c2b9e383a4e2979de281b4e281b8e383955c305c725c30e281b8e383955c30e3808d5c30e281b8e383955c30255c30e29780e383a05c303030375c30e281b476616c65e281b8e1b6a05c305c6ee1b589095c6e5c30c2b2e383a8e1b6a05c30c2b25c30e1b6a05c30c2b9e38384e2979d5c6e5c30415c225c30c2b9e1b6a05c6e5c30c2b9e281b55c30e3808d5c305c72e1b5895c30e383b2e281b4e3829b5c30e28198e383b2c2b9e1b69c5c6ee3808ce1b6a05c30e281b45c30e3808ce1b6a05c30e1b69c5c")
    (hex 36096 "30e280a25c305c30c2a55c305c6ee1b6a05c30e380825c30e38081e1b6a05c30285c30e281b7e383845c303f5c30e281b7e383845c30595c30e29780e383a05c30735c30c2b3e383845c30595c30e3808ce383a05c307b5c30e1b69cc2b2222c0a2d2d20737061206672616e636f726368616d70730a22c2b2e1b587c2b366696ee281b6e3829b5c303e5c30e383a3e281b5c2b2e1b6a05c72c2b9e1b589285c30303030c2b95c72c2b95c725c6e5c3050c2b9e1b6a0c2b9e383ad5c6e5c305c30e281985c304609e383afc2b9e383ab5c6e5c30c2b2e383af09e380815c6e5c30e3829c5c30e281b7e383abc2b9235c30c2b3e383ab5c30235c30e281985c6e")
    (hex 36352 "5c302a5c30e380815c6e5c303030355c30e280a25c305c303f5c30e380815c6e5c30435c30e296a1e383a85c30575c30e3808ce383a8e2979c575c30e281b6736f75726365e281b4e3829b5c3053e3829c5c30e28198c2b9e1b589c2b9e383a0235c3040c2b9e3838ce3829b5c30303033c2b25c30e296b6c2b9e1b69cc2b9e1b69c375c30e296a1e38082c2b9e1b6a0e1b69ce3808ce383a65c30e281b65c30e281b7e383a6c2b2285c30e281b8e383a6c2b23c5c30e281b7e383a65c30465c30c2b3e383a65c30465c30e281985c725c303c5c30c2b3e1b6a0e281b4525c30e281985c725c30485c30c2b3e1b6a0e281b4665c30e296a1e1b69c5c30f09f98")
    (hex 36608 "905c30e29780e383a05c30675c3020e281b7e383a76e5c30e281b472616964e281b75c6e5c30e382a8e383abe2979de3839ee383a8e1b69cc2b9e3808d5c6e5c30e382bf095c30e382b7e28198c2b9e1b589c2b9e3808de3808d5c30e38287e281b85c305c30e1b69cc2b9e3808de281b85c30e3828fe383a8e2979de38383c2b9e1b589325c3052e1b587c2b9e1b69cc2b2e28198e383a0e281985c3058e281b7c2b9e1b6a0c2b2e1b6a0e383ace1b6a05c30e3838be281b85c30c2b95c72c2b2e1b587e383ace281b5c2b3e38395c2b2e3808c5c30e3808ce38395e2979c2d5c30e296a1e383955c302d5c30e28199e1b6a0c2b9415c30e28199e1b6a0c2b9")
    (hex 36864 "485c30c2b36b656de281b4555c3042c2b3c2b9e28198235c3052e383a3c2b2e1b6a05c72c2b9e1b69c285c3040c2b9e1b69ce3808d5c305c30e1b69ce281b7e383a95c30e281b55c30e281b7e383a95c30e3808d5c30e281b7e383a95c302d5c30e281b7e383a95c30415c30e3829ce1b69c5c303c5c30e296a1e1b69c5c30405c3020e383a5e383a7545c30e28199095c30535c3020e281b6e383a7545c30e296aee1b5895c30525c30e296a0e1b589e383a3525c3020e383a5e383a7e381a65c30e281b6636f6d626573e281b7e281985c306de3808c5c30e3838ce28198c2b9e1b589c2b9e38384e281985c307de38395e2979de38383e281b6c2b9e1b589")
    (hex 37120 "c2b9e1b69cc2b2e3838ae28198e281b85c3060c2b95c72c2b909e281985c3041e281985c30c2b95c6e5c6e5c3041e3808c5c30c2b95c6e285c305c225c6ec2b9e1b589e281985c3072e28096c2b2e1b6a05c72c2b95c72c2b9e1b6a05c72e3808de382b95c30e3808d5c30e28199e383a85c303030375c30e29780e383a85c303a5c30e3808ce383a85c30415c30e281b7e383a4c2b9465c3020e383a5e383a77a5c30e296a1e383a05c30e288a75c30e296a1e383a0e2979ce288a75c30e296aee383a05c305f5c30e296a0e383a0e383a35f5c30e3829ce1b6a05c306e5c30e296aee281985c306b5c30e296a0e28198e383a36b5c30e281b462727578093c")
    (hex 37376 "5c3059e3808c5c305c6ec2b9e1b589c2b9e38395235c3074e3838cc2b9e1b6a0c2b9e1b6a0c2b9e1b6a0e3808d5c3065e3839be2979de383b2c2b9e1b589c2b9e1b6a0415c3070c2b2e1b6a05c72c2b95c72c2b2e383a8e1b6a0e1b6a05c3041c2b35c30c2b2e383a8e1b6a0e281b55c304ce383a3e281b5c2b2e383a8e1b6a0e281b55c3040c2b2e383a8e1b6a0e281b55c304ce383b2e281b7c2b9e383a8235c3040c2b9e383a8e281b4c2a5e281b75c30645c30c2a5e281b75c30615c30e280a25c305c30e382a85c3009e1b6a0c2b2e383925c30e281b4706f7568e281b7e3808d5c3079e3839ee2979d5c6ec2b95c72c2b9e1b589c2b9e383a0e281b85c")
    (hex 37632 "3069e383afe2979de296aec2b9e1b69cc2b9e383a0e3808d5c3069e383a9e2979de28198c2b9e1b589c2b2e3829be383a0e3829b5c3060c2b9e1b69cc2b2e3829be383a0e281985c3060c2b9e1b589c2b9e383a8e281985c307e09e383a3e281b5c2b9e1b589c2b9e1b589c2b9e383a8e281b55c3040c2b9e383a8e1b5875c6ee28198c2b2e281b45c30e3808ce297805c30e1b6a05c305c6ee3808d5c30e280965c30e3808ce297805c30215c30e28199e297805c302d5c30e3808ce3808d5c30525c30e3808ce3808d5c304a5c305c6ee3829bc2b95a5c305c6ee28198c2b9735c30e296a1e3829b5c30675c30e280a25c305c30f09f90b15c30e281b66361")
    (hex 37888 "6d707573e281b7e281985c307de296a05c30e383a8e281b8c2b9e1b69cc2b95c72c2b9e3838ce1b6a05c3059e296a05c30e1b6a0c2b9e1b589c2b9e3838ce281b65c3040c2b2e383a0e28198e3808d5c306de383a2e2979de383b2e281b8c2b9e1b589c2b9e3829be281985c30e1b69ce383a3e281b5e281b55c305c30e281985c302ce38383e281b8c2b9e1b6a0e281b5e280a25c305c30535c30e28199e281985c30425c30e29780e281985c30485c30c2a5e383ade2979d6b5c30e281b8e383955c307e5c30e281b473746176e281b6e3808d5c3045e280965c30e383abc2b9e382b9e281985c305c30e3808d5c3041e280965c30c2b9e3838c285c3041c2")
    (hex 38144 "b25c30c2b9e3838ce3829b5c3041c2b95c30c2b2e38395e1b6a0285c3041c2b25c30c2b2e383a0e1b6a0e281b7e3808ce383955c30415c30e296a1e383955c30475c30e3808ce38395e2979c475c30e296a1e1b5895c30555c30e29780e1b589e2979c555c30e296aee1b69c5c30505c30e296a0e296ae5c304f5c30e281b4626c616ee1b587e3829b5c3040c2b2e383a0e1b6a0e281b55c304ce383a3e281b5c2b2e383a8e1b6a0e281b55c3040c2b2e383a8e1b6a0e281b55c302fe383ade2979d5c30e383b2e281b8c2b9e1b589e3829b5c3041e383abe2979dc2b2e383a0e28198e3829b5c3040c2b2e3808de383a0e281985c3041e383afe2979dc2b2e3")
    (hex 38400 "808de383a0e281b85c3041e3839ee2979dc2b2e38395e28198325c3048e296aec2b2e383a0e3808d285c3049e281b65c30e3829bc2b9e38395e3808d5c30e296aec2b9e1b69ce281b5e280a25c305c30255c30c2a5e383835c30e381ab5c30c2a5e383835c30e381bb5c30c2a5e281b65c30e381bb5c30c2b3e3839ec2b3e3838e5c30e281b463686963c2b2e3829b5c3009c2a55c30e281b7e3829b5c302de3838ce2979de383a3e281b5c2b2e1b6a0e1b69cc2b9e28198e382b95c30e1b6a05c30e1b69cc2b2222c0a2d2d2073757a756b610a22c2b2e281b5e281b57374617274e281b85c6e5c303ce383ade281b4c2b9e1b6a0c2b95c723c5c302ce383ad")
    (hex 38656 "e281b4c2b95c72e281985c30e281b8e1b6a0e281985c3020c2b2e1b6a05c72235c30475c6e5c305c6ee383a8c2b9e38395235c3051e1b5895c30c2b9e1b589c2b9e38384e1b6a05c30e281b4e3839ee281985c3064e383a8c2b2e1b6a0e1b589c2b9e381ace296a0e1b5875c305c30e281985c30e38081e1b6a05c305c305c30e38081e1b6a05c305c6e5c30e38081e1b6a05c30e281985c30e38081e1b6a05c30e3829b5c30e38081e1b6a05c30285c30e38081e1b6a05c303030325c30e281b8e383a05c305c305c30e281b7e383a05c30e280965c30e280a25c305c30415c30e296a1e383a0e383a3285c30e3829ce281b85c30485c30e281b7e383955c30")
    (hex 38912 "e288a75c3020e383b2e383a7555c30e38081e3829b5c30e382ad5c30e281b7e3838c5c30e381ad5c30c2a55c6e5c30685c30e281b473637276e281b8e3808d5c30e1b6a0e383a9e2979dc2b9e383a3e3829be3829b5c30e1b5875c725c30e28198e1b6a0e281985c30e1b69ce383a8e281b5e3808d5c30e281b5e383aae2979de383b22a5c3053e1b5895c30e28199c2b2e1b6a0e1b589c2b9e383845c6e5c3043e383a5e2979de383b2c2b9e3828de3808d5c3073e383a6e2979d5c30c2b2e1b6a05c72c2b9e1b69cc2b928285c3041e383aae2979dc2b93ce1b587e38082e3829b5c305c6e5c30e3808ce383955c302e5c30e281b8e3838c5c307d5c30e380")
    (hex 39168 "8de281985c30e382ad5c30e3808d5c6e5c30e382865c30e29780375c30205c30e281b8e3838c5c303030375c30e3808c325c305e5c30e28198e281985c305f5c30e1b69ce383a0e383a54b5c30e281b7e383a05c30e2ac85efb88f5c30e281b66465676e657209e3808d5c3068e1b6a0c2b95c72c2b9e383a85c6e5c30e382afe1b5875c3009c2b2e1b6a0e1b589c2b9e383a8e281985c3040c2b9e383a8e3808d5c305de296ae5c30e383a3e281b5c2b9e1b589c2b9e383955c6e5c305c30e3829b5c30e296a1e383adc2b95c72e281985c3070c2b2e1b6a05c72c2b2e1b6a05c72c2b9e383a0e1b6a05c30735c725c305c30c2b9e1b589c2b95c72c2b9e382")
    (hex 39424 "a6e296a15c3060c2b9e1b69cc2b9e1b6a0e1b587e3829ce382a65c302d5c30e280a25c305c30555c30e3808ce383a85c30465c30e3808ce383ad5c30645c30e3808c5c6e5c30645c30e296a15c6e5c305d5c305c6ee1b6a05c30735c3020e383a7e383a7e298895c30e281b8e382b95c30e3818b5c3021e38292e2979d555c30213ae2979d555c30c2b26870e296ae3c5c304be3838ae2979d5c30e1b69cc2b2462de281985c3020c2b95c72e3808d5c3079e281b75c305c6ec2b2e1b6a0e1b589c2b2e1b6a05c72c2b2e383a0e383845c6e5c304be1b5875c30e1b69ce281b6c2b2e383a0e38384e281985c30c2b3e281b85c30e383a5e281985c304de281b8")
    (hex 39680 "5c30e383aae28198c2b9e383a0e3808d5c30e281b7095c30e383afe3838ce281985c30625c30c2b9e1b69cc2b9e3829be3829b5c3061e383a2e2979dc2b2e1b6a0e1b69cc2b9e3829be3808d5c30c2b9e383abe2979de1b6a05c3047e383a0e2979de28198e383adc2b9e3829be3829b5c304fe2979de2979d5c30e383b3e281b7c2b9e3829b285c30e2978be2979de2979de383afe383a3e281b5c2b95c72c2b95c72c2b9e1b6a0325c30425c30c2b2e1b6a0e296b6e3808d5c3060c2b2e1b6a05c72c2b9e383afe3808d5c30e296aec2b2e1b6a05c72e1b58909e296a15c303d5c30e280a25c305c30e2978b5c3020e383a7e383a7505c30e3808ce3808d5c")
    (hex 39936 "30e382b75c3009235c30e3839e5c30e297805c6e5c302fc2b9e280a25c305c305ac2b9e3808ce281b85c3064c2b9e280a25c305c30f09f90b1c2b9c2a5e383b25c306ac2b9e296a15c6e5c30e38191c2b9e296a15c6ee2979ce38191c2b9e3808de383ab5c30e381aec2b920c2b3e383a7e381adc2b9c2b3636173e281b6e281985c303de383a9e2979de383b2e1b69cc2b2e1b6a0e1b589c2b2e1b6a0e1b589e3829b5c30c2b9e383afe2979de3829b5c302ce38383e281b4c2b9e1b69ce281985c30e281b5e280965c30e383a0e281985c305c72e3839fe2979de383b2e28198235c302d5c725c30e383ade281b4c2b95c72e281b6e280a2e2979d5c304f5c")
    (hex 40192 "30e3808de296a15c30275c30e3808de281985c303a5c30e281b8e3838c5c30565c30e281b8e3838c5c30635c30e281b7e383a05c30e296885c305c72c2b2220a7d0a0a5f5f6766785f5f0a30303030303030306363636363636363303030303030303030303030373737373030303030303030303030303030303030303030303030303030303030303030393963636363636338313131313131313131313131313838383831313131313131313131313131386363636363363737643164636337373764316463633637370a30303030303030303737373737373737303030303030303737373737373736373030373730303030303030303030303030303030")
    (hex 40448 "303030303030303030303030633637636363636338313131313131313131313131383131313138313131313131313131313131386363633131643737643131313737373764313131643637370a30303730303730303737373737373737303030373637373736363737373737373737373730373030303037373030303030303030303030303030303030303030353537373735356338313131313131313131313138313030303031383131313131313131313131386363633131643736313131313737373631313131643637360a3030303737303030373737373737373730373737373736363737373737373737363637373737373737373737373737303030")
    (hex 40704 "3030303030303030303030303030353539393935353938636363636363636363636338313030303031386363636363636363636363386363633131643531313131313664353131313131363635360a30303037373030303737373737373737363636363737373737373737373636373636363636363737303636373736363730303030303030303030303030303030636363636363636338313131313131313131313831313030303031313831313131313131313131386363316464313131643531313131313164353164313131370a303037303037303037373737373737373030303737363637363636373636363736363737303030303030373636303030")
    (hex 40960 "30303030303030303030303030303030636363636363636338313131313131313131313831313030303031313831313131313131313131386363373736313131363737363131316436373731313131370a30303030303030303737373737373737303030303030303037363730303037303030303030303030303030303030303030303030303030303036363838363638636363636363636338636363636363636363383131313131313131313138636363636363636363386363373664313131363737373131316436373731313131630a30303030303030306363636363636363303030303030303030303030303030303030303030303030303030303030")
    (hex 41216 "303036363838363638383636383836363838636363636363636338636363636363636363383131313131313131313138636363636363636363386363353131356436313135643135643631313531353564630a64646464646464646562656262626565303030306230303030303030303030623230303030303030303030303030303030373737373737306363636363636363636363636363636338636363636363636363383131316262626231313138636363636363636363386363313131373737313131313737373731313131643737630a6464646464646464656262626562626530303030623030303030303030303062653030303030303030303030")
    (hex 41472 "3030303030353537373535306363636363636363636363636363636338636363636363636363383131656237376265313138636363636363636363386364313131373737313131313737373731643131643737630a64646464646464646265656532656565303030626532303030303030303065656532303030303030303030303030303030303037373030306363636363636363636363636363636338636363636363636338313165626262626262653131386363636363636363386364313164373736313131313737373631643131643737630a646464646464646462626265653265653030656232303030303030303030306565303030303030303037")
    (hex 41728 "37373730303030303037373030306363636363636363636363636363636338636363636363636338313139313131313131393131386363636363636363386336646431313531366435313664353136363564646435630a64646464646464646265656562326532303030626565303030303030306562623230323030303030303036363030303030303037373030306363636363636363636363636363636338636363636363636338313137373737373737373131386363636363636363386337373631313131373737363131313137373736313163630a64646464646464646265653265656532306530656232323030303030303065626530653030303030")
    (hex 41984 "303030303030303030303035353030306363633232323232323232323263636338636338383863633831363737363636363636373736313863633838386363383637373731313131373737373131316437373764313163630a64646464646464646562656565323232306262656530303030303030623062656565323230303030303030303030303030303030303030306363323232323232323232323232636338636361616163633864646436363737373736366464643863636161616363383737636363633131373737643131316437373664313163630a6464646464646464656532326565326562626565326532303030303030656565653230303030")
    (hex 42240 "3030303030303030303030303030303030306363323232323232323232323232636338636363636361633164643838383838383838383864643163616363636363386363636363636363636336643131636363633631313163630a35353535353535356565326562656262626262656565653230303030623062306262623030303030303030303030303063636363636363313131313131313131313131313232383838383838383838383838386666383838616161616161616161616161383838383838323231313131313131313131313131636363636363630a353535353535353565323262626262626262626262623232303030626262623062623030")
    (hex 42496 "62623030303030303030303063636363636331323131313131313131313132313161616161616161613838383838666666383838386161616161616131316161616161316161613131323131313131313131313132316363636363630a35353535353535356562656262656562626562656265656530623030626565626265306562303030303030303030303063636363636331353231323231323132323235313161313131313131316138386138666666383838386161616161616131616161313131313131613131353232323132313232313235316363636363630a35353535353535356262626262626265656562626565626262626230306262656565")
    (hex 42752 "626265656530303030303030303063636363636331353232353532323532353532313131313131313131316161386138666666383838386161616161616131616131313131313131313131323535323532323535323235316363636363630a35353535353535356262626265626262656262656565656530626262656262626562626530306565303030303030303063636363633132313232323231323232323531313131313131313131313161386138666666383838386161616161616131616131313131313131313131313532323232313232323231323163636363630a3535353535353535656262626262626565656565653265323030626262626265")
    (hex 43008 "6565656565326532303030303030303063636363633132313131313131313131313531313131313164643131313131386138666638383838386161616161616131616131313131313131313131313531313131313131313131323163636363630a35353535353535356262626562656565653265323265653262306265626565656532653232653030383636383836363063636363633131313131313131313131313231316464313131316464313131616138383838616161613131616161616161613131313131313131646431313231313131313131313131313163636363630a353535353535353562626262656265653232656565653232626262626562")
    (hex 43264 "65653232656565303232383836363838363663636363633131313131313131313131313131313531646431313131646431616138386161383838386161313161616161313131313131316464313531313131313131313131313131313163636363630a63636363636363636265656265326532326265656565653262656562653265323262656565656532303030303030303063636363383831313131313131313131313131313531313164643131313131316138613838383838386161616131616131313131313164643131313531313131313131313131313131313838636363630a63636363636363636262626565656532626265653232326562626265")
    (hex 43520 "656565326262656532303030303030303030303063636363666131313131313131313131313131313531313131316464313164646161383838383838386161616161316164643131646431313131313531313131313131313131313131316166636363630a63636363636363636562656565326565626565653232326565626565653265656265656532303230303030303030303063636363666131313131313131313131313131313531313131313131646431316161383838383838386161616161616131316464313131313131313531313131313131313131313131316166636363630a6363636363636363656265323265626565656532326532323062")
    (hex 43776 "6532326562656565653232653232303030303030303063636366386161616161616161616161313131313531313131316464313131613861383838383838386161616161613161313131646431313131313531313131616161616161616161616138666363630a63636363636363636562656265656565656532326532326530626562656565656565323265323230303030303030303063636338616161616161616161616161616161616161616161616161616161616638613838383838616161616161613161616161616161616161616161616161616161616161616161616161386363630a636363636363636362326532656565326565656532653265")
    (hex 44032 "30653065656530326565653032303230303030303030303063636338613838383838383838383838383838383838383838383838383838383866616138383838616161616161316138383838383838383838383838383838383838383838383838383861386363630a63636363636363636565323265323232653265326262653230303065323030326532653030303030303030303030303063636338616331313131313131313131313131313131313131313131313131313161616161383861616161616131616131313131313131313131313131313131313131313131313131316361386363630a63636363636363636565326565653232323232656565")
    (hex 44288 "326530303030656530323230326530303030383836363838363663636361616363313131313131313131313131313131636363636363636363313131616161616161616161616131313131636363636363636363313131313131313131313131313131636361616363630a36643664366436643030303030303030363636363636363636363636363636363636363636363664636363636363636363636363636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6436643664366436303030303030303036353535")
    (hex 44544 "3535353535353535353535353535353535356435636363636363636363636363636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a36643664366436643030303030303030363530303030303030303030303030303030303030303635633535633535636335356363633535633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a643664366436643630303030303030303635")
    (hex 44800 "30303030303030303030303030303030303030303635356363356363356363633563356363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64646464646464643030303030303030363530303030303030303030303030303030303030303635636363636363636363636335636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64366436643664363838383838383838")
    (hex 45056 "363530303030303030303030303030303030303030303635636363636363636363636363636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64646464646464643838383838383838363530303030303030303030303030303030303030303635636363636363636363636363636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6464366464643664383838383838")
    (hex 45312 "3838363530303030303030303030303030303030303030303635636363636363636363636363636363633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64646464646464643030303030303030363530303030303030303030303030303030303030303635636331313131313131636363633131313131316363636363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a646464646464646430303030")
    (hex 45568 "30303030363530303030303030303030303030303030303030303635636331363631363631313131313136313136313131316363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64646464646464643030303030303030363530303030303030303030303030303030303030303635636331363136313631363636313136313131313636316363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64646464646464643030")
    (hex 45824 "303030303030363530303030303030303030303030303030303030303635636331363136313631363136313636363131363131316363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64356464643564643030303030303030363530303030303030303030303030303030303030303635636331363136313631363136313136313131313136316363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6464646464646464")
    (hex 46080 "3636363636363636363530303030303030303030303030303030303030303635636331363136313631363636313136316331363631316363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a35643564356435643636363636363636363530303030303030303030303030303030303030303635636331313131313131313131313131316331313131636363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a646464646464")
    (hex 46336 "64643636363636363636363530303030303030303030303030303030303030303635636363636363636363636363636363636363636363636363303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64356435643564356363353664356363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a35643564")
    (hex 46592 "356435646363353664356363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a64356435643564356363353664356363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3564")
    (hex 46848 "3564356435646363353664356363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a35353535353535356363636363636363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a")
    (hex 47104 "35643564356435646363636363636363363530303030303030303030303030303030303030303635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a35353535353535356363636363636363366436363636363636363636363636363636363636363635303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 47360 "300a35356435353564356363636363636363643535353535353535353535353535353535353535353535303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3535353535353535303030303030303030303031303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 47616 "3030300a35353535353535353030303030303030303031373130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a353535353535353530303030303030303030313637313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 47872 "30303030300a35313535353135353030303030303030303031363637313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a35353535353535353030303030303030303031366431303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 48128 "303030303030300a31353135313531353030303030303030303031643130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3531353135313531383838383636363630303031303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 48384 "3030303030303030300a31313131313131313838383836363636303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633030303030")
    (hex 48640 "30303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633030303030303030636363636363303030303030303030303030303030300a63636363636363636363636330303030303030303030636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363636363303030")
    (hex 48896 "303030303030303030303030300a63636363636363636363303037373737373737373730636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363636363303030303030303030303030303030300a6363636363636363633037373737373737373737373063636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363303737373737373063636363636330")
    (hex 49152 "3030303030303030303030303030300a63636363636363303037373737373737373737373730636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363636363303030303030303030303030303030300a636363636363303037373737373737373737373737306363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636330373737373737306363636363")
    (hex 49408 "63303030303030303030303030303030300a63636363636330373737373737373737373737373730636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363636363303030303030303030303030303030300a63636363633037373737373737373737373737373730636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363")
    (hex 49664 "636363303030303030303030303030303030300a63636363633039393939393939393930303030303030636363636363636363636363303030303030306363636363633030303030303030303063636363636363636363636363303030303030303030636363636363636363636363633030303030303039393939393930636363636363303030303030303030303030303030300a6363636330393939393939393930303838383838383063636363636363636363633039393939393930636363636330303939393939393939393030636363636363636363633030393939393939393930636363636363636363633030393939393930303939393939393063")
    (hex 49920 "6363636363303030303030303030303030303030300a63636363303939393939393930303830303030303030636363636363636363633039393939393939306363633030393939393939393939393939303063636363636363633039393939393939393939393063636363636363633039393939393939303039393939393930636363636363303030303030303030303030303030300a636363633039393939393939303830633030303030303030306363636363633039393939393939393063636330393939393939393939393939393930306363636363633039393939393939393939393939306363636363633039393939393939393030393939393939")
    (hex 50176 "30636363636363303030303030303030303030303030300a63636363303939393939393930306363303939393939393930306363636330393939393939393939306363303939393939393939393939393939393930636363636330303939393939393939393939393939306363636330393939393939393939303039393939393930636363636363303030303030303030303030303030300a63636363303939393939393930636363303939393939393939306363636330393939393939393939306330393939393939393939393939393939393939306363636330393939393939393939393939393939306363633030393939393939393939303039393939")
    (hex 50432 "393930636363636363303030303030303030303030303030300a63636363303939393939393930636363303939393939393939393063636330393939393939393930306330393939393939393939393939393939393939306363636330393939393939393939393939393939306363633039393939393939393939303039393939393930636363636363303030303030303030303030303030300a6363636330393939393939393063636330393939393939393939306363633039393939393930303030633039393939393930303030303939393939393930636363633039393939393930303039393939393930636363303939393939393030303030303939")
    (hex 50688 "3939393930636363636363303030303030303030303030303030300a63636363303939393939393930636363303939393939393939393063636330393939393939303838306330393939393939303838383830393939393939306363633039393939393930383830393939393939306363633039393939393930383838303039393939393930636363636363303030303030303030303030303030300a636363633039393939393939303063633030303939393939393930636330393939393939393030306330393939393939393030303030303939393939393063636330393939393939303030303939393939393063633039393939393939303030303030")
    (hex 50944 "39393939393930636363636363303030303030303030303030303030300a63636363303838383838383838303063303838303838383838383063633038383838383830306363633030383838383838306363636330383838383838306363633038383838383830636330383838383838306363303038383838383830636363633038383838383830636363636363303030303030303030303030303030300a63636363303038383838383838383030303030303838383838383063633038383838383830306363633030383838383838303030303030383838383838306363633038383838383830636330383838383838306363303038383838383830303030")
    (hex 51200 "303038383838383830636363636363303030303030303030303030303030300a63636363303038383838383838383838383838383838383838383063633038383838383830636363636330383838383838383838383030383838383838306363633038383838383830636330383838383838306363633038383838383838383838383838383838383830636363636363303030303030303030303030303030300a6363636363303038383838383838383838383838383838383838306363303838383838383063636363633038383838383838383838303038383838383830636363303838383838383063633038383838383830636363303838383838383838")
    (hex 51456 "3838383838383838383030636363636363303030303030303030303030303030300a63636363633038303838383838383838383838383838383838303063633038383838383830636363636330303838383838383838383030383838383838306363633038383838383830636330383838383838306363633030383838383838383838383838383838383063636363636363303030303030303030303030303030300a636363636363303030343434343434343434343434343434303030636330343434343434306363636363303830343434343434343430303434343434343063636330343434343434306363303434343434343063636330383034343434")
    (hex 51712 "34343434343434343434303063636363636363303030303030303030303030303030300a63636363636363303830343434343434343434343434343030306363633034343434343430636363636363303030343434343434343030343434343434306363633034343434343430636330343434343434306363636330303034343434343434343434343430303063636363636363303030303030303030303030303030300a63636363636363303038303034343434343434343434303038306363633034343434343430636363636363633038303034343434343030343434343434306363633034343434343430636330343434343434306363636363303830")
    (hex 51968 "303434343434343434303038306363636363636363303030303030303030303030303030300a63636363636363636330383830303030303030303030383830636363633030303030303030636363636363636330383030303030303030303030303030306363633030303030303030636330303030303030306363636363633038303030303030303030303830306363636363636363303030303030303030303030303030300a6363636363636363636330303838383838383838383830306363636363303838383838383063636363636363636330383838383838303038383838383830636363303838383838383063633038383838383830636363636363")
    (hex 52224 "6330383838383838383838383063636363636363636363303030303030303030303030303030300a63636363636363636363636330303030303030303030636363636363633030303030303030636363636363636363633030303030303030303030303030306363633030303030303030636330303030303030306363636363636363303030303030303030306363636363636363636363303030303030303030303030303030300a636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 52480 "63636363636363636363636363636363636363636363636363303030303030303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363303030303030303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363633030303030636363636363636363636363636363636363636363636330303030303030303030303030")
    (hex 52736 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363303737373737306363636363636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6363636363636363636363636330303030303030303063636363636363636363636363636363636363636330373737373730636363636363636363636363636363636363636363633030303030303030303030")
    (hex 52992 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636363633030373737373737373737303063636363636363636363636363636363636330373737373737306363636363636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363636363633030373737373737373737373730306363636363636363636363636363636363303037373737373063636363636363636363636363636363636363636363303030303030303030")
    (hex 53248 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636330303737373737373737373737373730306363636363636363636363636363636330303737373737306363636363636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636330373737373737373737373737373737306363636363636363636363636363636363303030303030306363636363636363636363636363636363636363636330303030303030")
    (hex 53504 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363633039393939393939393939393939393939393063636363636363636363636363636363303838383838306363636363636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6363636363636363303939393939393939393939393939393939306363636363636363636363636363633030303030303030636363303030303030303063633030303030303030633030303030")
    (hex 53760 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363633039393939393930303030393939393939393063636363636363303030303030306330393939393939306363633039393939393930636330393939393939306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363636330393939393939303838303939393939393930636363636363303939393939393063303939393939393063636330393939393939306363303939393939393063303030")
    (hex 54016 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363633039393939393030303030393939393939393063636363633039393939393939306330393939393939306363633039393939393930636330393939393939306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303939393939393030303039393939393939393063636363303939393939393939306330393939393939306363633039393939393930636330393939393939306330")
    (hex 54272 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303939393939393063303939393939393939393063636330393939393939393939306330393939393939306363633030393939393930636330393939393939306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6363636363636330393939393939306330393939393939393939306363633039393939393939393930633039393939393930636363303039393939393930303039393939393930")
    (hex 54528 "6330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303939393939393063303939393939393939303063636330393939393939393930306330393939393939306363636330393939393939393939393939393939306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363633039393939393930633039393939393939303030636363303939393939393030303063303939393939393063636363303039393939393939393939393939")
    (hex 54784 "39306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303939393939393063303939393939393030306363636330393939393939303838306330393939393939306363636330303039393939393939393939393030306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303838383838383063303030303030303830306363633038383838383838303030636330383838383838306363636363303038383838383838383838")
    (hex 55040 "383030306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303838383838383063303838383838383030636363633038383838383830306363636330383838383838306363636330303838383838383038383838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6363636363636330383838383838306330303030303030636363636363303838383838383030636363633038383838383830636363633038383838383830303038")
    (hex 55296 "3838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303838383838383063636363636363636363636363633038383838383830636363636330383838383838306363636330383838383838303830383838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363633038383838383830636363636363636363636363636330383838383838306363636363303838383838383063636363303838383838303830")
    (hex 55552 "30383838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303838383838383063636363636363636363636363633038383838383830636363636330383838383838306363633038383838383830306330383838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303434343434343063636363636363636363636363633034343434343430636363636330343434343434306363633034343434343430")
    (hex 55808 "636330343434343434306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303434343434343063636363636363636363636363633034343434343430636363636330343434343434306363633034343434343430636330343434343434306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6363636363636330343434343434306363636363636363636363636363303434343434343063636363633034343434343430636363303434343434")
    (hex 56064 "3430636330343434343434306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303030303030303063636363636363636363636363633030303030303030636363636330303030303030306363633030303030303030636330303030303030306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a636363636363633038383838383830636363636363636363636363636330383838383838306363636363303838383838383063636330383838")
    (hex 56320 "38383830636330383838383838306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363303030303030303063636363636363636363636363633030303030303030636363636330303030303030306363633030303030303030636330303030303030306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 56576 "636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6c6162656c5f5f0a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 56832 "636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630a6363636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 57088 "6363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630a636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 57344 "63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633737373763636363636363373737376363636363636363636363636363373737376363636337373763636363636363636363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 57600 "636363636363636363636363636363636363636363636363633737373737636363636337373737376363636363636363636363636363373737376363636337373763636363636363636363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633737373737636363636337373737376363636363636363636363636363373737376363636337373763636363636363636363636363636363636363636363636363630a6363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 57856 "6363636363636363636363636363636363636363636363636363633737373737376363633737373737376363636337373737376363636337373737373737376337373763636337373737376363636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633737373737376363633737373737376363633737373737373763636337373737373737376337373763633737373737373737636363636363636363636363636363630a636363636363636363636363636363636363636363636363636363636363636363")
    (hex 58112 "63636363636363636363636363636363636363636363636363636363633737373735373763373735373737376363373737353535373737636335373737373535356335353563633737373535353737636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633737373763373763373763373737376363373737636363373737636363373737376363636363636363633737373737633535636363636363636363636363636363630a63636363636363636363636363636363636363636363636363636363636363")
    (hex 58368 "636363636363636363636363636363636363636363636363636363636363633737373763353737373563373737376337373737636363373737376363373737376363636363636363633737373737373763636330303030303030306363636363630a63636363636363636363636363636363636363636363636330303030303030303030306363636363636363636363636363636363636363636363636363633737373763633737376363373737376335373737636363373737356363373737376363636363636363633535353537373763636330373737373737306363636363630a6363636363636363636363636363636363636363636330303737373737")
    (hex 58624 "3737373737306363636363636363636363636363636363636363636363636363633737373763633537356363373737376363373737636363373737636363353737376363636363636363376363636337373763636330373737373737306363636363630a63636363636363636363636363636363636363636330373737373737373737373730306337376363636363636363636363636363636363636363636363633737373763636335636363373737376363353737373737373735636363633737373737376363636363373737373737373763633037373737373730306363636363630a636363636363636363636363636363636363633030373737373737")
    (hex 58880 "37373737373730303737373737376363636363636363636363636363636363636363633737373763636363636363373737376363633537373737373563636363633537373737376363636363353537373737373563633037373737373730306363636363630a63636363636363636363636363636363636330303737373737373737373737373730303636373736363763636363636363636363636363636363636363633535353563636363636363353535356363636335353535356363636363636335353535356363636363636335353535356363633037373737373730306363636363630a63636363636363636363636363636363633037373737373737")
    (hex 59136 "373737373737373730636337363663636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363633037373737373730636363636363630a63636363636363636363636363636363303037373737373737373737373737373730636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363303030303037373737373730636363636363630a6363636363636363636363636363636330373737373737")
    (hex 59392 "3737373030303030303030636363636363636363636330303030303030636363636363633030303030303030306363636363636363636363636363633030303030303030636363636363636363636363633030303030303030303737373737373030636363636363630a63636363636363636363636363636330616161616161616130303838383838383830636363636363636363303061616161616130636363636330306161616161616161613030636363636363636363636330306161616161616161303063636363636363636363303061616161613030306161616161613030636a63636363630a636363636363636363636363636363306161616161")
    (hex 59648 "616130383838383838383838306363636363636363303061616161616161306363633030616161616161616161616161613063636363636363633030616161616161616161616130306363636363636330306161616161616130303061616161616130306a6a6a636363630a6363636363636363636363636363306161616161616130303838303030303030306363636363636363303061616161616161613063633030616161616161616161616161616161306363636363633030616161616161616161616161613063636363636330306161616161616161303030616161616161306a6a6a6a6a6a6a630a63636363636363636363636363633061616161")
    (hex 59904 "61616130383030633030303030303030636363636330306161616161616161613030306161616161616161616161616161616161306363636363633061616161616161616161616161616130636363633061616161616161616161303030616161616161306a336a316a6a316a0a636363636363636363636363633061616161616161303830636330616161616161613063636363633061616161616161616130303030616161616161616161616161616161616130636363636330616161616161616161616161616161613063636330306161616161616161613030306161616161613030336a6a6a6a31316a0a6a63636363636363636363636330616161")
    (hex 60160 "616161613030306363306161616161616161306363633030616161616161616130303030616161616161616161616161616161616161613063636330306161616161616161616161616161616130636363306161616161616161613030303061616161616130306a336a6a6a6a31310a6a63636363636363636363636330393939393939393030636363303939393939393939306363633039393939393939303030303039393939393939303030303030393939393939393063636330393939393939303030303039393939393930636330393939393939393030303030303039393939393930306a6a6a6a6a316a6a0a6a6a63636363636363636363633039")
    (hex 60416 "39393939393930636363633039393939393939393063636330393939393939303838383030393939393939303038383838303939393939393930636363303939393939393038383830393939393939306363303939393939393038383838303030393939393939306a7272336a727272720a6a6a636363636363636363636330393939393939393063636363303939393939393939303333723039393939393930383830303039393939393930383838383830393939393939393063636330393939393939303838383039393939393930636330393939393939303838383030633039393939393930726a727272727233720a6a6a726a636363636363636363")
    (hex 60672 "303939393939393930306a33723030393939393939393033723039393939393930383030303039393939393930383030303030303939393939393030636330393939393939303030303039393939393930306330393939393939393030303030303039393939393930307272723372727233330a6a6a336a6a636363636372637230393939393939393930617233303430393939393939307233303939393939393030636363303939393939393930306a316a3130393939393939303063633039393939393930306a6a3039393939393930306a30393939393939393033336a3330303939393939393030723333727233336a330a6a337272336a6a6a636363")
    (hex 60928 "72723038383838383838383830303030303038383838383830336a30383838383838303063636330383838383838383030303030303038383838383830306363303838383838383030333330383838383838303033303838383838383830303030303038383838383838303072333372336a6a33720a33723333336a6a6a6a6a72726a30303838383838383838383838383838383838383830303372303838383838383063636363303838383838383838383838303030383838383838306a6a6a303838383838383072726a3038383838383830336a303838383838383838383838383838383838383830306a336a7233336a6a72720a33726a336a6a6a6a6a")
    (hex 61184 "6a6a6a3330303838383838383838383838383838383838383830306a72303838383838383063636363303038383838383838383838303030383838383838306a6a6a30383838383838306a336a30383838383838307272303038383838383838383838383838383838383030306a6a336a33336a6a72330a7233333372726a6a6a6a6a333330383038383838383838383838383838383838383038306a30383838383838303036636363303038383838383838383830303038383838383830306a6a3038383838383830306a723038383838383830303372303038383838383838383838383838383838383038306a6a336a6a6a336a336a0a33337233723372")
    (hex 61440 "6a6a6a33727233303030383838383838383838383838383838303830723330383838383838303063636363303030383838383838383830303038383838383830306a6a3038383838383830307236303838383838383030336a3038303838383838383838383838383838303038307233723372336a727236360a72337272333333336a7272336a7230383030343434343434343434343434343038383033333034343434343430306363636a6a3030303434343434343430303034343434343430306a6a3034343434343430303633303434343434343030333372303030343434343434343434343434303038303072727233333636727233720a6a72726a6a")
    (hex 61696 "7233336a3333336a723330383030343434343434343434343030383830723633303434343434343036373434343430383030343434343434303030343434343434303434343034343434343430343672303434343434343072336a33303830303434343434343434343030383838307235363372337272333636720a3333333636366a6a336a6a3333727230303838303030303030303030303838383072363536303030303030303034343434343430303838303030303434303030303030303030303434343030303030303030343633303030303030303033333333333038383030303030303030303838383030333335333336367272723333330a363636")
    (hex 61952 "336a336a6a3333336a33336a35303038383838383838383838383838303336333634303838383838383034343434343434303038383838383030303030383838383838303434343038383838383830343636303838383838383072336a6a363030383838383838383838383838303036726a356a3333337236363633330a337233336a3372727234336a723636353630303838383838383838383830306a363336343630383838383838303434343434373737303038383838383830303038383838383830343434303838383838383034343630383838383838303333727233363030383838383838383838303072337233363536336a6a3333333372330a72")
    (hex 62208 "72723333727233363636363636363536363630303030303030303030336a363635363634303030303030303034343434343434343435303030303838303030303030303030303434343030303030303030343437303030303030303036336a72727236363030303030303030307272333372723335336a33363636333372330a333636363636363636366a6a7272333536363636366a3372337235333633363333373436363434343434343434343434343434343435313635353530303036353535353535353535343434343434343434343434343437363436723733376a36336a3336363636356a33333336363636363633333335333372333337366a3333")
    (hex 62464 "0a333637336a333637723333373333333572333633336a336a36333536366a3733333434343436343434343434343434343434343434303535353535353535353535353535353035353434343434343434343434343434343436343635363533333633373635366a357272373333377272723733333335363672723733723336370a727233363736723336363333363672353672353637333537333335363572353636363734343434343434343434343434343434343530353535353535353535353535353535353535343430303030303434343434343434343434363434343636343636333633363536373336373372363633723637353333363672336a33")
    (hex 62720 "36360a37727236353672723633376a6a723635336a3733353337356a373534373634383838383838363638383838383834343434343435303535353535353535353535353535353530353534303737373730383838383636383838383838373434343436343736333672353333333633723733363337727235723733727236373672720a363636336a3336366a33366a37333335376a3536377233363436353436343438383838613935363638383030303030303030303035353535353535353535353535353535353535353037373737373730386139353636613838383834373636343434353736303030307233367236366a723636333335363672333336")
    (hex 62976 "363672720a33336a3336726a723636336a363437353434373434343734363635343434343838383839343939393030373737373737373737303035353535353535353535353535353535353535303737373737373038353439393939383838383434363437363436363330373730336a3736333536336a33363635333336363333723336360a37373633336a3736333434363434363537363436363434363736353634343438383838353838303037373737373737373737373737303535353535353535353535353535353535353037373737373030383038383838303838383834343434343434353736303737303336353838383838383838383838383838")
    (hex 63232 "3838383838380a36363537343634343636343434363435343437343634363436343434343434343434343434303037373737373737373737373737373730353535363636363636363636363636363530373737373038303434343434343434343434343434343434343030303037373030303038383838383838383838383838383838383838380a373737373737373737373737373735643436343636363434343434343434343434343434303037373737373737373737373737373737373037373535373535353535353535353536303030303038383034343434343434343434343434343434343430373737373737373730383838383838383838383838")
    (hex 63488 "38383838383838360a64373737373737373737373737373564343434343434343434343434343434343434343030373737373737373737373737373737373737303535353535353535353535353535353530383838383830363434343434343434343434343434343434343037373737373737373038383838383838383838383835616161343939360a64343436373634343433343434343564343434343434343737373737373137343434343037373737373737373737373737373737373737303535353535353535353535303030303030303030303034343636343030303030303034343434303030303030303037373030303038383838383838383838")
    (hex 63744 "383830353939343439350a64343436343637333333333333333564303034373434343737373737373131303030343037373737373730303030303037373737373737303535373535353030303030303030303737373737373034343434303737373737373034343430373737373038383037373038383038383838383838383838383830356161613434610a6430303434343433333333333333356435303031303030313434343434303030303530373737373737303838383838303737373737373730353535353030373737373737303030373737373737303635343430373737373737303434343037373737303030303737303030303838383838383838")
    (hex 64000 "3838383830353539393934390a64353030343433333333333333333564303030303035353530343434303030303531306161616161613038383838303061616161616161303535353030616161616161613030306161616161613035353635306161616161613034343430616161616161303030303034343438383838383838383838383835353539393934390a643535303434333333333333333335303030303035353135303333353030303031303061616161616130303030306161616161616161613035353030616161616161616130303061616161616130303535353061616161616130343434306161616161613030383830343434383838383838")
    (hex 64256 "38383838383838353534343434390a64303135373333333333333333333530303030303531303035303333303030303130306161616161613035353061616161616161616130303530306161616161616161613030306161616161613035353535306161616161613036363430616161616161303030303034343438383838383838383838383838353530303034390a33333030313030303030303333333330303030303531363035303333303030303530616161616161303035306161616161616161616130303530616161616161616161303030616161616161303035353535306161616161613036353061616161616130303434343434343438383838")
    (hex 64512 "383838383838383838353530303534340a33303030353030303035303033333330303030303530313035303333303030303530616161616161303035306161616161616161613038303030616161616161616130303030616161616161303035353535306161616161613030303061616161616130303434343434343434343434343434343434343434343434343434340a30303035313131313131303030336a303030303035313035306a353535303030313039393939393930303530393939393939393930303035303939393939393930303030303039393939393930303535353530393939393939393939393939393939303030343434343434343434")
    (hex 64768 "3434343434343434343434343434343434340a30303030353131313135303030333330303030303535353530353535353535353730393939393939303535303939393939393930303830353039393939393930383838303030393939393939303535353535303039393939393939393939393939303030353535353535343434343434343434343434343434343434343434340a30303030303030303030303030306a6a3030303030353030353535353535353735303939393939393035353039393939393030383830353530393939393939303838303030303939393939393035353535353030303939393939393939393939303038303030353535353535")
    (hex 65024 "34343434343434343434343434343434343434340a35353535353535353535353535353535353535353535353535353535353537353039393939393930303530303030303030303838303035303939393939393038303030303039393939393930303535353535303939393939393939393939393939303030353535353535353536363535343434343434343434343434343434340a35353535353535353535353535353535353535353535353535353535353537353039393939393930303530383838383838383830303535303939393939393030353535303039393939393930303535353530393939393939393939393939393939393035353030303535")
    (hex 65280 "303030303035353535353535353434343434343434340a35353535353535353535353535353535353535353535353535353535353735353038383838383830303530383838383838303035353535303838383838383030353535353038383838383830303535353038383838383830303030303838383838383036353535353535353535353030353535353535353535353534343434340a3535353530303035353535353535353535353535353535353535353537353535303838383838383035353030303030303030353535353530383838383838303035353535303838383838383036363535303838383838383038383830383838383838303536353535")
    (hex 65536 "3535353535353535353535353636363535353535353434340a35353535353535353535353535353535353535353535353535353537353535353038383838383830353535353535353535353535353535303838383838383035353535353038383838383830353535353038383838383830383838303838383838383035353635353535353535353535353535353131303030303035353535350a353535353535353535353535353535353535353535353535353537353535353038383838383830303535353535353535353535353535303838383838383030353535353038383838383830303535353038383838383830303030303838383838383030353535")
    (hex 65792 "36353535353535353535353535353535353535353530303030350a35353535353535353535353535353535353535353535353535353635353535303434343434343030353535353535353535353535353530343434343434303035353535303434343434343030353535303434343434343030353530343434343434303035353536353535353535353535353535353030303035353530303030350a35353535353535353535353535353535353535353535353535363535353535303434343434343030353535353535353535353535353530343434343434303035353535303434343434343030353535303434343434343030353530343434343434303035")
    (hex 66048 "353535363535353535353535353535353535353030303035353535350a35353535353535353535353535353535353535353535353536353535353535303434343434343035353535353535353535353535353530343434343434303535353535303434343434343035353535303434343434343035353530343434343434303535353535353635353535353535353535353535353535353535353535350a3535353535353535353535353535353535353535353535353635353535353530303030303030303535353535353535353535353535353030303030303030353535353530303030303030303535353530303030303030303535353030303030303030")
    (hex 66304 "3535353535353635353535353535353535353535353535353535353535350a35353535353535353535353535353535353535353535353635353535353535303838383838383035353535353535353535353535353530383838383838303535353535303838383838383035353535303838383838383035353530383838383838303535353535353536353535353535353535353535353535353535353535350a353535353535353535353535353535353535353535353536353535353535353038383838383830353535353030303035353535353535303838383838383035353535353038383838383830353535353038383838383830353535303838383838")
    (hex 66560 "38303535353535353536353535353535353535353535353535353535353530300a35353535353535353535353535353535353535353535363535353535353535303030303030303035353535353535353535353535353530303030303030303535353535303030303030303035353535303030303030303035353530303030303030303535353535353535363535353535353535353535353535353535353535350a35353535353535353535353535353530303535353535363535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535")
    (hex 66816 "353535353535353535353535363535353535303035353535353535353535353535350a30303030303030303030303030303030303135353535363535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535363530303031303030303030303030303030303030300a3030303030303030303030303030303030303135353635353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535353535")
    (hex 67072 "3535353535353535353535353535353635353130303030303030303030303030303030300a35353535353535353535353535303030303030353536353535353535353535353535353537373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373535353535353535353535353535353635353030303030303535353535353535353535350a313131313131313131313131303030303030303535363535353535353535353535353537373637373736373737363737373637373736373737363737373637373736373737363737373637373736373737363737373637373736")
    (hex 67328 "37373735353535353535353535353535353635313030303030303031313131313131313131310a30303030303030303030303030303030303030303635353535353535353535353535353737353535353535353535353535353535373737373535353535353535353535353535353535353535353535353535353535353535353535373735353535353535353535353535353536303030303030303030303030303030303030300a30303030303030303030303030303030303030303635353535353535353535353563363736353038383030383838303830303035363736373530303030303030303030303030303030303030303030303030303030303030")
    (hex 67584 "303035373637633535353535353535353535353536303030303030303030303030303030303030300a30303030303030303030303030303030303030303635353535353535353563636337373637353030383030383038303830303035373637363530723072307230723072307230723072303930393039303930393038303830303035363736376363633535353535353535353536303030303030303030303030303030303030300a3030303030303030303030303030303631303031363535353535353563633737373636363635303038303038383830383838303536363636353072307230723072307230723072307230393039303930393039303830")
    (hex 67840 "3830303035363636363737376363353535353535353136313030313631303030303030303030303030300a31313131313131313131303030303035363030363135353535356363373737373736363636353030383030303038303830383035363736363530723072307230723072307230723072303930393039303930393038303830303035363636363737373737636335353535353131363030363536303030303131313131313131310a353535353535353535353030303030353631303631353535636337373737373736363636363530383838303030383038383830353636363635303030303030303030303030303030303030303030303030303030")
    (hex 68096 "30303030303035363636363637373737373763633535353130363031363536303030303535353535353535350a31313131313131313131303030303635353631363135636337373737373763633636363636353535353535353535353535353535363636363535353535353535353535353535353535353535353535353535353535353535353535363636363663633737373737376363353130363136353535303030303131313131313131310a31313131313131313131303030303635353631366363373737373737636363733636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636")
    (hex 68352 "363636363636363636363636363673636363373737373737636331363136353535303030303131313131313131310a30303030303030303030303030303635353663633737373737376363636373633636363636363636363636363636363636363636363636363635353535353535353535363535353636363636363636363636363636363636363636363636363663736363636337373737373763633136353535303030303030303030303030300a3030303030303030303030303030363563633737373737376363637363736373363536363635363636353636363536363635363636353635353535353838353535353535353535353535363636353636")
    (hex 68608 "3635363636353636363536363635363673637363736363633737373737376363353535303030303030303030303030300a30303030303030303030303030316363373737373737636363637363737373733636363636363636363636363636363636363635353535353530303038383030303030353030303535353535363636363636363636363636363636363636363673737373637363636363373737373737636335303030303030303030303030300a303030303030303030303031636337373737373763636373637363737373737335363536353635363536353635363536353535353535353030303030383830303030303030303030303535353535")
    (hex 68864 "35363536353635363536353635363536353673737373736373637363636337373737373763633130303030303030303030300a31313131313131313131636337373737373763636363736373737373737373733635363536353635363536353635363535353535303030303030303030383830303030303030303030303030303535353635363536353635363536353635363573737373737373736373636363633737373737376363313031313131313131310a35353535353535356363373737373737636363736373637373737373737373733535353535353535353535353535353535353030303030303030303030383830303030303030303030303030")
    (hex 69120 "303035353535353535353535353535353535353573737373737373737363736373636363373737373737636331353535353535350a31313131313163633737373737376363636373637373737373737373736a73353636363636363636363636363635353030303030303030303030303030383830303030303030303030303030303030303535353536363636363636363636363635736a73737373737373737363736363636337373737373763633131313131310a3131313163633737373737376363637363736373737373737373737373733535353535353535353535353535353530303030303030303030303035353535353535353530303535303030")
    (hex 69376 "3030303030303030353535353535353535353535353535357373737373737373737373637363736363633737373737376363313131310a3031636337373737373763636363736373737373737373737373736a7335353535353535353535353535353535353030303030303030303030353030303030313030303535303035353030303030303030303035353535353535353535353535353535736a7373737373737373737373637363636363373737373737636331300a636337373737373763636373637363737373737373737373737373733535353535353535353535353535353530303030303030303035353535303031303031373130303031303030")
    (hex 69632 "30353530303030303030303035353535353535353535353535353535737373737373737373737373736373637363636337373737373763630a373737373737636363637363737373737373737373737373736a733535353535353535353535353535353530303030303030303535353530303031373130303130303031373130303035353530303030303030303035353535353535353535353535353535736a737373737373737373737373736373636363633737373737370a37373737636363736373637373737373737373737373737373733535353535353535353535353535353530303030303030353535353530303030303130303030303030303130")
    (hex 69888 "303030303535353530303030303030303535353535353535353535353535353573737373737373737373737373737363736373636363373737370a37376363636373637373737373737373737373737373737373353535353535353535353535353535353030303030303035353535353030303130303030303030303030303030303130303035353535303030303030303035353535353535353535353535353535737373737373737373737373737373737363736363636337370a6363637363736373737373737373737373737373737373733535353535353535353535353535353530303030303035353535353535303031373130303030303030303030")
    (hex 70144 "3030313731303035353535353530303030303035353535353535353535353535353535357373737373737373737373737373737373637363736363630a6363736373737373737373737373737373737373736a7335353530303030353535353535353535303030303030303535353535353030303031303030303030303030303030303031303030303535353535353030303030303535353535353535353535353535353535736a7373737373737373737373737373737373637363630a637363737373737373737373737373737373737373733535353035353535303535353535353530303030303030353535353535353030303030303030303030303030")
    (hex 70400 "30303030303030303030353535353535353030303030303035353535353530303030303031313535737373737373737373737373737373737373736373630a737373737373737373737373737373737373736a733535353035333733333530353535353535303030303030303535353535353530303031303030303030303030303030303030303031303035353535353535353030303030303535353535353030303535363736353535736a737373737373737373737373737373737373730a73737373737373737373737373737373737373733535353530353333333335303535353535353030303030303535353535353535303031373130303030303030")
    (hex 70656 "393939393030303031373130353535353535353035303030303035353535353530303035353637363535353573737373737373737373737373737373737373730a73737373737373737373737373737373736a73353535353530357233337235303535303535303030303030353030353535353535303030313030303030303030303030303939393930313030353535353535303035303030303030353530353530303030303031313535353535736a73737373737373737373737373737373730a7373737373737373737373737373737373733535353535353035337272333530353030353030303030303035303030353535353530303030303030303030")
    (hex 70912 "3030303030303030303030303030353535353530303137353030303030353535303535353535353535353535353535357373737373737373737373737373737373730a73737373737373737373737373737373733535353535353535363535353536353530353530303030303035303030303535353535303030303130303030303030303030303030303130303030353535353530303131353030303030303535303535353535353535353535353535353573737373737373737373737373737373730a737373737373737373737373737373733535353535353535353536363636353535303535303030303035393939303035353535353530303137313030")
    (hex 71168 "30303030303030303030313731303035353535353530313731303530303030303535303535353535353535353535353535353535737373737373737373737373737373730a737373737373737373737373736a736a3535353535353535353531313131353535353530303030303035303031303035353535353530303031303030303030303030303030303031303030353535353535303031303035303030303035353035353535353535353535353535353535356a736a737373737373737373737373730a73737373737373737373737373736a6a353535353535353535303434343430353535353030303030353030313731303535353535353530303030")
    (hex 71424 "3031303030303030303031303030303035353535353535303137313035303030303030353535303030303030313135353535353535356a6a73737373737373737373737373730a73737373737373737373736a736a736a3535353535353535303438373838343035353530303030303530303131303035353535353535363030303137313030303030303137313030303635353535353535303031313035303030303030353535303030353536373635353535353535356a736a736a73737373737373737373730a7373737373737373737373736a6a6a3035353535353535353034383838383430353530303030303530303137313035353535353535353530")
    (hex 71680 "3030303130303030303030303130303030353535353535353535303137313035303030303035353530303035353637363535353535353535306a6a6a7373737373737373737373730a7373737373737373736a736a736a6a6a3530353535303535303466383866343035353030303030353030303130353535353535303535353636313030303030303030303031363136363531353531353535353535353535303030303030353535303030303030313135303535353035356a6a6a736a736a7373737373737373730a737373737373737373736a6a6a306a303535353535353535303438666638343035353030303030353030303136353535353535353535")
    (hex 71936 "35353536363636363636363636363636363636363636363635353535303030303030303030303030353535353535353535353535353535353535306a306a6a6a737373737373737373730a7373737373737373736a736a6a6a306a3035303530353035353634343434363530353530303030303530313635353035303531353135313535363636363635353535363636363636363636363636303030303030303030303030303030303535353535353535353530353035303530356a306a6a6a736a7373737373737373730a73737373737373736a6a6a306a303030353535353535353535353636363635353535303030303035363636353535353535353636")
    (hex 72192 "3636363636363636363536363636353636363636363636363636303030303030303030303030303030303535353535353535353535353535353535353030306a306a6a6a73737373737373730a73737373736a736a736a6a6a306a303035303530353035303530353135313530353530303030303035353535353535303030363636363636363636363536363737363635363636363636363636363030303030303030303030303030303035353530353035303530353035303530353030306a306a6a6a736a736a73737373730a7373737373736a6a6a306a303030303030353035303530353035303530353035353530303030303030303030303030303030")
    (hex 72448 "363636363636363636363536373636373635363636363636363636363030303535353530303030303030303035353035303530353035303530353035303530303030306a306a6a6a7373737373730a7373736a736a736a6a6a306a30303030353035303530353035303530353035303535303030303030303030303030303030303636363636363636363635363636363636353636363636363636363635353530353035353535353030303030353535303530353035303530353035303530303030306a306a6a6a736a736a7373730a737373736a6a6a306a303030303030303035303530353035303530353035303535353030303030303030303030303030")
    (hex 72704 "30303636363636363636363637353636363635373636363636353135313530353035303530353035353030303030353530353035303530353035303530353035303030303030306a306a6a6a737373730a736a736a736a6a6a306a3030303030303030303030303030303030303030303035353030303030303030303030303035353536363636363636363636363735353535373636363130303030303030303030303030303030303530303030303535303030303030303030303030303030303030303030306a306a6a6a736a736a730a73736a6a6a306a303030303030303030303530353035303530353035303530353535303030303030303030353535")
    (hex 72960 "3535303531353135313636363636363637373737363636363035303530353035303530353035303530353030303030353535303530353035303530353035303530353030303030303030306a306a6a6a73730a736a736a6a6a306a303030303030303030303030303030303030303030303030353530303030303535353535303030303030303030303030303136363636363636363636363130303030303030303030303030303030303530303030303535303030303030303030303030303030303030303030303030306a306a6a6a736a730a6a6a6a306a303030303030303030303030303530303035303030353030303530353530303030303530303530")
    (hex 73216 "303035303030353030303530303035313636363636363636313035303030353030303530303035303030353530303030303535303030353030303530303035303030353030303030303030303030306a306a6a6a0a0a5f5f6d61705f5f0a303030303330333033303039306130623063333033303330303030303030303030303030303031353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303432343334333433343334333433343334333433343334343330333033303330333033303330333033303330333033303330333033303330343534363830383138323833383438353836")
    (hex 73472 "383738383839386138623863386463306331633263336334633563366337633830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303033303137313831393161316231633137313833303035303030303030303230333034303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303035323533353335333533353335333533353335333533353433303330333033303330333033303330333033303330333033303330333033303030303039303931393239333934393539")
    (hex 73728 "36393739383939396139623963396464306431643264336434643564366437643830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030323632373238323932613262326332643265326630303030303031353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030353235333533353335333533353335333533353335333534333033303330333033303330333033303330333033303330333033303330333030303030613061316132613361346135")
    (hex 73984 "6136613761386139616161626163616465306531653265336534653565366537653830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303336333733383339336133623363336433653366303030303030303030303030303030303030303030303030303031333134303030303030303030303233323430303132313331343030303030303030323332343532353335333533353335333533353335333533353335343330333033303330333033303330333033303330333033303330333033303330303030306230623162326233623462")
    (hex 74240 "356236623762386239626162626263626466306631663266336634663566366637663830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303234303030303030303030303030303030303030303030303030323332343233323430303030323332313232323332323231323431333134303032333331333235323533353335333533353335333533353335333533353433303330333033303330333033303330333033303330333033303330333033303030303035353536353730303030")
    (hex 74496 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030313631363136313631363136313631363136313631313234303031333134313331343030303030303030303032333231323231313332323432333232333133323331333233313332323332343233323232313232353235333533353335333533353335333533353335333534333033303330333033303330333033303330333033303330333033303330333030303030303030303030303030")
    (hex 74752 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030323132323234323332343233323430303030323332343233323133313332323132313232333133323131323132323231323231313331333233313332333133323532353335333533353335333533353335333533353335343330333033303330333033303330333033303330333033303330333033303330303030303030303030303030")
    (hex 75008 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303031363136313631363136313631363136313631363331333231313331333233313332323432333331333233313331333231313331333133323131323132323331333233313332323132323231323231313231323235323533353335333533353335333533353335333533353433303330333033303330333033303330333033303330333033303330333033303030303030303030303030")
    (hex 75264 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303032353335333530303030303030303030303030303030303030303036303630373731373134313531343135313431353134313531343135313431353137313731363236333633363336333633363336333633363336333634333033303330333033303330333033303330333033303330333033303330333030303030303030303030")
    (hex 75520 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303136313631363136313631363136313631363136343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303330363133303330333033303330333033303330363133303330333033303330333033303330333033303330333033303330333033303330303030303030303030")
    (hex 75776 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313030303030303030303030303030303030303030303030303033303330333033303330333033303330333033303330333033303330333033303030303030303030")
    (hex 76032 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130303030303030303030303030303030303030303030303030333033303330333033303330333033303330333033303330333033303330333030303030303030")
    (hex 76288 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030353035303530353035303530353035303530353035303530353035303530353035303530353035303530353035303530353035303530353035303530353035303030303030303030303030303030303030303030303030303330333033303330333033303330333033303330333033303330333033303330303030303030")
    (hex 76544 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303630363036303630363036303630363036303630363036303630363036303630363036303630363036303630363036303630363036303630363036303630363030303030303030303030303030303030303030303030303033303330333033303330333033303330333033303330333033303330333033303030303030")
    (hex 76800 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303037303730373037303730373037303730373037303730373037303730373037303730373037303730373037303730373037303730373037303730373037303730303030303030303030303030303030303030303030303030333033303330333033303330333033303330333033303330333033303330333030303030")
    (hex 77056 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030333033303330333033303330333033303330333033303330333033303330333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303330333033303330333033303330333033303330333033303330333033303330303030")
    (hex 77312 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303330333033303330333033303330333033303330333033303330333033303330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 77568 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303033303330333033303330333033303330333033303330333033303330333033303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 77824 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030333033303330333033303330333033303330333033303330333033303330333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 78080 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303330333033303330333033303330333033303330333033303330333033303330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 78336 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303033303330333033303330333033303330333033303330333033303330333033303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 78592 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030323032303230323032303230323032303230323032303230323032303230323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 78848 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303230323032303230323032303230323032303230323032303230323032303230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 79104 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303032303230323032303230323032303230323032303230323032303230323032303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 79360 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030323032303230323032303230323032303230323032303230323032303230323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 79616 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f7366785f5f0a363530633030303830393333303039343330313533333031353433303039333330303934333031353333303135343330303033303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 79872 "3030303030303030303030303030303030303030303030303030303030303030303030303030300a3035306330303030316430353331643031333239363030303030303031643435333164343133323836303430303030303239363334303030303031643035333164303133316434353331643431333339303133303030303031643035333164303133323836303430303030303164343533316434313332383630343030303030323936333430303030303164303533316430313331643435333164343133333930313332393630350a3035306330303030316430353331643031333239363030303030303031643435333164343133323836303430303030")
    (hex 80128 "303239363334303030303031643035333164303133316434353331643431333339303133303030303031643035333164303133323836303430303030303164343533316434313332383630343030303030323936333430303030303164303533316430313331643435333164343133323936333532393633350a3131306330303030316334353531633433303161343535316134333031633435353163343330313834353531383433303163343535316334333031613435353161343330316334353531633433303138343535313834333031633435353163343330316134353531613433303163343535316334333031383435353138343330316334353531")
    (hex 80384 "633433303161343535316134333031633435353163343330323134353032313435300a3635306330303038303433333030343433303130333330313034333030343333303034343330313033333031303433303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a31313063303030303166343530316634353031663435303166343530316634343031663434303166343430316634343031663434")
    (hex 80640 "30316634343031663434303166343430316634333231663433323166343332316634333231663433323166343332316634333231663433323166343232316634323231663432323166343230316634323231663432323166343232316634323231663431323166343132316634313231663431320a36353063303030383037333330303734333031333333303133343330303733333030373433303133333330313334333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 80896 "30303030303030303030303030303030303030303030303030303030300a3131306330303030316634353531663433303164343535316434333031663435353166343330316134353531613433303166343535316634333031643435353164343330316634353531663433303161343535316134333031663435353166343330316434353531643433303166343535316634333031613435353161343330316634353531663433303164343535316434333031663435353166343330316134353031613435300a313130633030303031633435303163343530316334353031633435303163343430316334343031633434303163343430316334343031633434")
    (hex 81152 "3031633434303163343430316334333231633433323163343332316334333230303030303030303030316334343031633434303030303030303030303031633434303163343430303030303030303030303163343430316334343030303030303030303030316334343031633434300a313130633030303031633435303163343530316334353031633435303163343430316334343031633434303163343430316334343031633434303163343430316334343031633433323163343332316334333231633433323163343530316334353531633435303163343530316134353031613435303163343530316334353031643435303164343530316334353031")
    (hex 81408 "6334353031613435303161343530313834353031383435300a3035306330303030316430353331643031333239363030303030303031643435333164343133323836303430303030303239363334303030303031643035333164303133316434353331643431333339303133303030303031643035333164303133323836303430303030303164343533316434313333393031333030303030316434343331643434333161343433316134343331353434333135343433313334343331333434330a3239306330303230323837353032383735303238373530323837353032383735303238373530323837353232383735323238373432323837343232383734")
    (hex 81664 "323238373432323837333232383733323238373332323837333232383732323238373232323837313232383731323030373030303037303030303730303030373030303037303030303730303030373030303037303032363735303236373530323437353032343735300a3239306330303230323637353032363735303236373530323637353032363735303236373530323337353032333735303166373530316637353031663735303166373530316637343231663734323166373432316637343231663733323166373332316637333231663733323166373232316637323231663731323166373132303037303030303730303030373030303037303030")
    (hex 81920 "303030303030303030303030303030303030300a3239306330303230323637353032363735303236373530323637353032363735303236373530323637353032363735303236373430323637343032363734303236373430323637333232363733323236373332323637333232363732323236373232323637313232363731323030373030303037303030303730303030373030303030303030303030303030303030303030303030303030303030303030303030303030303030300a32393063303032303236373530323637353032363735303236373530323637343032363734303236373430323637343032363733323236373332323637333232363733")
    (hex 82176 "32323637323232363732323236373132323637313230303030303030303030303030303030303030303030303030303030303030303030303030303030323837353032383735303238373530323837353032363735303236373530323637353032363735300a32393063303032303234373530323437353032343735303234373530323437353032343735303233373530323337353032313735303231373530323137353032313735303231373430323137343232313734323231373432323137333232313733323231373332323137333232313732323231373232323137313232313731323231373030323137303032313730303231373030323137353032")
    (hex 82432 "31373530323337353032333735300a3635306330303038303533333030353433303131333330313134333030353333303035343330313133333031313433303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a323930633030323032343735303234373530323437353032343735303234373430323437343232343734323234373432323437333232343733323234373332323437333232343732")
    (hex 82688 "3232343732323234373132323437313230303030303030303030303030303030303030303030303030303030303030303030303030303030323637353032363735303236373530323637353032343735303234373530323437353032343735300a363530633030323030373333303037343330313333333031333433303037333330303734333031333333303133343330303733333030373433303133333330313334333030373333303037343330313333333031333433303038333330303834333031343333303134343330303833333030383433303134333330313434333030383333303038343330313433333031343433303038333330303834333031")
    (hex 82944 "3433333031343433300a3035306330303030316430353331643031333239363030303030303031643435333164343133323836303430303030303239363334303030303031643035333164303133316434353331643431333339303133303030303031643435333164343533316434313331633435333163343533316334313331613435333161343533316134313331383435333138343533313834313331643435333163343533316134353331383435330a3239306330303230323637353032363735303236373530323637353032363735303236373530323637353032363735323236373432323637343232363734323236373432323637333232363733")
    (hex 83200 "323236373332323637333232383735303238373530323837353032383735303238373030323837303032383735303238373530323837303232383730323238373430323837343032383730323238373032323837343032383734300a3131306330303030313533333031353333303135333330313533333031353333303135333330313533333031353333303135333330313533333031353333303135333330313533323031353332323135333232313533323231353332323135333232313533323231353332323135333232313533323231353332323135333232313533313231353331323135333132313533313231353331323135333132313533313231")
    (hex 83456 "353331320a3635306330303030303933333030393433303135333330313534333030393333303039343330313533333031353433303039333330303934333031353333303135343230303933323030393432303135333230313534323030393332303039343230313533323031353432303039333230303934313031353331303135343130303933313030393431303135333130313534313030393331303039343130313533313031353431300a5f5f6d757369635f5f0a30302030303432343334340a30302030303432343334340a30302030303432303134340a30302030303432303234340a30302030303033303134340a30302030343035303234340a")
    (hex 83712 "30302030363037303134340a30302030343038303234340a30302030303033303134340a30302030343035303234340a30302030363037303134340a30302030343039306134340a30302030303537303130620a30302030343538303230630a30302030303537303130620a30302030343538303230640a30302030363539303130650a30302030303537303130660a30302031303432303131310a30302031323432313331340a30302030303033303134340a30302030343035303234340a30302030363037303134340a30302030343038306134340a30302030303033303134340a30302030343035303234340a30302030363037303134340a30302030")
    (hex 83968 "343039313334340a30302030303135303134340a30302030303432303134340a30302030303432343334340a30302031363432343334340a30302032393432343334340a0a")))
