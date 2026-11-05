#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : Cherry Bomb (cherrybomb-0.p8)
;; Source ROM : assets/roms/pico/cherrybomb-0.p8 (66416 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "ascent")
  (title "Cherry Bomb (cherrybomb-0.p8)")
  (rom-source "pico/cherrybomb-0.p8")
  (rom-bytes 66416)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label sfx music))
    (lua-line-count 1715)
    (lifted-function-count 57)
    (gfx-row-count 119)
    (map-row-count 0)
    (gff-row-count 0)
    (sfx-row-count 52)
    (music-row-count 24))
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
    (lifted-functions (_draw _init _update aimedfire animate animatestars big_shwave bigexplode blink boss1 boss2 boss3 boss4 boss5 cherbomb col cprint doenemy dofade doshake draw_game draw_over draw_start draw_wavetext draw_win dropickup drwmyspr drwoutline explode fire firespread killen makescore makespr makestars move nextwave page_blue page_red pickattac pickfire picktimer placens plogic popfloat smol_shwave smol_spark spawnen spawnwave starfield startgame startscreen update_game update_over update_start update_wavetext update_win))
    (pico8-api-calls (abs add all atan2 btn btnp camera circ circfill cls cos del flr min music pal print pset rectfill rnd sfx sin spr))
    (structured-loops 11)
    (structured-conditionals 50)
    (lifted-state-machines 2)
    (lifted-high-level-idioms 5)
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 0)
    (active-sfx-lifted 32)
    (active-music-lifted 23))
  (pico8-state-machines
    (def-pico-state-machine pico8_lifecycle_fsm #:hooks (_init _update _draw) #:update-states (_update draw_game move startgame update_game update_over update_start update_wavetext) #:draw-states (_draw draw_game draw_over draw_start draw_wavetext draw_win drwmyspr firespread))
    (def-pico-state-machine pico8_entity_dispatch_fsm #:mechanism foreach-all-iterator #:registered-handlers (_draw _init _update aimedfire animate animatestars big_shwave bigexplode blink boss1)))
  (high-level-idioms
    (idiom-pico8-entity-iterator #:apis (foreach all add del) #:call-sites 46)
    (idiom-pico8-sprite-batch-render #:apis (spr sspr pal palt cls) #:call-sites 38)
    (idiom-pico8-fixed-point-physics #:apis (flr sin cos abs min max) #:call-sites 68)
    (idiom-pico8-input-poll #:apis (btn btnp) #:call-sites 18)
    (idiom-pico8-audio-trigger #:apis (sfx music) #:call-sites 25))
  ;; --- 4. Symbolic MMIO Cross-Reference, State Machines, Idioms & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function
      (name _init)
      (params ())
      (line-range (4 45))
      (api-calls (cls spr))
      (called-functions (cprint dofade startscreen))
      (structured-ast
        (for-loop "i=0,30"))
      (body-lines
        "function _init()"
        " --this will clear the screen"
        " cls(0)"
        " "
        " cartdata(\"cherrybomb\")"
        " highscore=dget(0)"
        " "
        " version=\"v1\""
        " "
        " startscreen()"
        " blinkt=1"
        " t=0"
        " lockout=0"
        " "
        " shake=0"
        " flash=0"
        ""
        " debug=\"\""
        " "
        " peekerx=64"
        " "
        " -- logo ani --"
        "\tfadetable={{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},{1,1,129,129,129,129,129,129,129,129,0,0,0,0,0},{2,2,2,130,130,130,130,130,128,128,128,128,128,0,0},{3,3,3,131,131,131,131,129,129,129,129,129,0,0,0},{4,4,132,132,132,132,132,132,130,128,128,128,128,0,0},{5,5,133,133,133,133,130,130,128,128,128,128,128,0,0},{6,6,134,13,13,13,141,5,5,5,133,130,128,128,0},{7,6,6,6,134,134,134,134,5,5,5,133,130,128,0},{8,8,136,136,136,136,132,132,132,130,128,128,128,128,0},{9,9,9,4,4,4,4,132,132,132,128,128,128,128,0},{10,10,138,138,138,4,4,4,132,132,133,128,128,128,0},{11,139,139,139,139,3,3,3,3,129,129,129,0,0,0},{12,12,12,140,140,140,140,131,131,131,1,129,129,129,0},{13,13,141,141,5,5,5,133,133,130,129,129,128,128,0},{14,14,14,134,134,141,141,2,2,133,130,130,128,128,0},{15,143,143,134,134,134,134,5,5,5,133,133,128,128,0}}"
        ""
        " cls(12)"
        " spr(10,40,34,6,5)"
        " cprint(\"a lazy devs game\", 64,80,7)"
        " cprint(\"by krystian majewski\", 64,86,7)"
        " "
        " fadeperc=1"
        " "
        " repeat"))
    (def-pico-function
      (name dofade)
      (params ())
      (line-range (61 65))
      (api-calls (flr min pal))
      (called-functions ())
      (structured-ast
        (for-loop "c=0,15"))
      (body-lines
        "function dofade()"
        " fadeperc=min(fadeperc,1)"
        " for c=0,15 do"
        "  pal(c,fadetable[c+1][flr(fadeperc*16+1)],1)"
        " end"))
    (def-pico-function
      (name _update)
      (params ())
      (line-range (68 83))
      (api-calls ())
      (called-functions (update_game update_over update_start update_wavetext update_win))
      (structured-ast
        (if-cond "mode==\"game\""))
      (body-lines
        "function _update() "
        " t+=1"
        " "
        " blinkt+=1"
        " "
        " if mode==\"game\" then"
        "  update_game()"
        " elseif mode==\"start\" then"
        "  update_start()"
        " elseif mode==\"wavetext\" then"
        "  update_wavetext()"
        " elseif mode==\"over\" then"
        "  update_over()"
        " elseif mode==\"win\" then"
        "  update_win()"
        " end"))
    (def-pico-function
      (name _draw)
      (params ())
      (line-range (87 100))
      (api-calls ())
      (called-functions (doshake draw_game draw_over draw_start draw_wavetext draw_win))
      (structured-ast
        (if-cond "mode==\"game\""))
      (body-lines
        "function _draw()"
        " doshake()"
        " "
        " if mode==\"game\" then"
        "  draw_game()"
        " elseif mode==\"start\" then"
        "  draw_start()"
        " elseif mode==\"wavetext\" then"
        "  draw_wavetext()"
        " elseif mode==\"over\" then"
        "  draw_over()"
        " elseif mode==\"win\" then"
        "  draw_win()"
        " end"))
    (def-pico-function
      (name startscreen)
      (params ())
      (line-range (107 111))
      (api-calls (music))
      (called-functions (makestars))
      (structured-ast
        (seq-block 5))
      (body-lines
        "function startscreen()"
        " makestars()"
        " mode=\"start\""
        " music(7)"
        "end"))
    (def-pico-function
      (name startgame)
      (params ())
      (line-range (113 156))
      (api-calls ())
      (called-functions (makespr makestars nextwave))
      (structured-ast
        (seq-block 44))
      (body-lines
        "function startgame()"
        " t=0"
        " wave=0"
        " lastwave=9"
        " nextwave()"
        " "
        " ship=makespr()"
        " ship.x=60"
        " ship.y=90"
        " ship.sx=0"
        " ship.sy=0"
        " ship.spr=2"
        "   "
        " flamespr=5"
        " "
        " bultimer=0"
        " "
        " muzzle=0"
        " "
        " score=0"
        " cher=0"
        " "
        " lives=4"
        " invul=0"
        " "
        " attacfreq=60"
        " firefreq=20"
        " nextfire=0"
        " "
        " makestars()"
        "  "
        " buls={}"))
    (def-pico-function
      (name makestars)
      (params ())
      (line-range (161 169))
      (api-calls (add flr rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=1,100"))
      (body-lines
        "function makestars()"
        " stars={} "
        " for i=1,100 do"
        "  local newstar={}"
        "  newstar.x=flr(rnd(128))"
        "  newstar.y=flr(rnd(128))"
        "  newstar.spd=rnd(1.5)+0.5"
        "  add(stars,newstar)"
        " end "))
    (def-pico-function
      (name starfield)
      (params ())
      (line-range (172 182))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "i=1,#stars")
        (if-cond "mystar.spd<1"))
      (body-lines
        "function starfield()"
        " "
        " for i=1,#stars do"
        "  local mystar=stars[i]"
        "  local scol=6"
        "  "
        "  if mystar.spd<1 then"
        "   scol=1"
        "  elseif mystar.spd<1.5 then"
        "   scol=13"
        "  end   "))
    (def-pico-function
      (name animatestars)
      (params (spd))
      (line-range (188 191))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "spd==nil"))
      (body-lines
        "function animatestars(spd)"
        " if spd==nil then"
        "  spd=1"
        " end"))
    (def-pico-function
      (name blink)
      (params ())
      (line-range (203 208))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "blinkt>#banim"))
      (body-lines
        "function blink()"
        " local banim={5,5,5,5,5,5,5,5,5,5,5,6,6,7,7,6,6,5}"
        " "
        " if blinkt>#banim then"
        "  blinkt=1"
        " end"))
    (def-pico-function
      (name drwoutline)
      (params (myspr))
      (line-range (213 218))
      (api-calls (spr))
      (called-functions ())
      (structured-ast
        (seq-block 6))
      (body-lines
        "function drwoutline(myspr)"
        " spr(myspr.spr,myspr.x+1,myspr.y,myspr.sprw,myspr.sprh)"
        " spr(myspr.spr,myspr.x-1,myspr.y,myspr.sprw,myspr.sprh)"
        " spr(myspr.spr,myspr.x,myspr.y+1,myspr.sprw,myspr.sprh)"
        " spr(myspr.spr,myspr.x,myspr.y-1,myspr.sprw,myspr.sprh)"
        "end"))
    (def-pico-function
      (name drwmyspr)
      (params (myspr))
      (line-range (220 228))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myspr.shake>0")
        (if-cond "t%4<2"))
      (body-lines
        "function drwmyspr(myspr)"
        " local sprx=myspr.x"
        " local spry=myspr.y"
        " "
        " if myspr.shake>0 then"
        "  myspr.shake-=1"
        "  if t%4<2 then"
        "   sprx+=1"
        "  end"))
    (def-pico-function
      (name col)
      (params (a b))
      (line-range (238 241))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "a.ghost or b.ghost")
        (return-expr "false"))
      (body-lines
        "function col(a,b)"
        " if a.ghost or b.ghost then "
        "  return false"
        " end"))
    (def-pico-function
      (name explode)
      (params (expx expy isblue))
      (line-range (261 291))
      (api-calls (add rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=1,30"))
      (body-lines
        "function explode(expx,expy,isblue)"
        " "
        " local myp={}"
        " myp.x=expx"
        " myp.y=expy"
        " "
        " myp.sx=0"
        " myp.sy=0"
        " "
        " myp.age=0"
        " myp.size=10"
        " myp.maxage=0"
        " myp.blue=isblue"
        " "
        " add(parts,myp)"
        "\t  "
        " for i=1,30 do"
        "\t local myp={}"
        "\t myp.x=expx"
        "\t myp.y=expy"
        "\t "
        "\t myp.sx=rnd()*6-3"
        "\t myp.sy=rnd()*6-3"
        "\t "
        "\t myp.age=rnd(2)"
        "\t myp.size=1+rnd(4)"
        "\t myp.maxage=10+rnd(10)"
        "\t myp.blue=isblue"
        "\t "
        "\t add(parts,myp)"
        " end"))
    (def-pico-function
      (name bigexplode)
      (params (expx expy))
      (line-range (314 342))
      (api-calls (add rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=1,60"))
      (body-lines
        "function bigexplode(expx,expy)"
        " "
        " local myp={}"
        " myp.x=expx"
        " myp.y=expy"
        " "
        " myp.sx=0"
        " myp.sy=0"
        " "
        " myp.age=0"
        " myp.size=25"
        " myp.maxage=0"
        " "
        " add(parts,myp)"
        "\t  "
        " for i=1,60 do"
        "\t local myp={}"
        "\t myp.x=expx"
        "\t myp.y=expy"
        "\t "
        "\t myp.sx=rnd()*12-6"
        "\t myp.sy=rnd()*12-6"
        "\t "
        "\t myp.age=rnd(2)"
        "\t myp.size=1+rnd(6)"
        "\t myp.maxage=20+rnd(20)"
        "\t "
        "\t add(parts,myp)"
        " end"))
    (def-pico-function
      (name page_red)
      (params (page))
      (line-range (364 369))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "page>5"))
      (body-lines
        "function page_red(page)"
        " local col=7"
        " "
        " if page>5 then"
        "  col=10"
        " end"))
    (def-pico-function
      (name page_blue)
      (params (page))
      (line-range (386 391))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "page>5"))
      (body-lines
        "function page_blue(page)"
        " local col=7"
        " "
        " if page>5 then"
        "  col=6"
        " end"))
    (def-pico-function
      (name smol_shwave)
      (params (shx shy shcol))
      (line-range (408 411))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "shcol==nil"))
      (body-lines
        "function smol_shwave(shx,shy,shcol)"
        " if shcol==nil then"
        "  shcol=9"
        " end "))
    (def-pico-function
      (name big_shwave)
      (params (shx shy))
      (line-range (422 431))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (seq-block 10))
      (body-lines
        "function big_shwave(shx,shy)"
        " local mysw={}"
        " mysw.x=shx"
        " mysw.y=shy"
        " mysw.r=3"
        " mysw.tr=25"
        " mysw.col=7"
        " mysw.speed=3.5"
        " add(shwaves,mysw)"
        "end"))
    (def-pico-function
      (name smol_spark)
      (params (sx sy))
      (line-range (433 450))
      (api-calls (add rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=1,2"))
      (body-lines
        "function smol_spark(sx,sy)"
        " --for i=1,2 do"
        " local myp={}"
        " myp.x=sx"
        " myp.y=sy"
        " "
        " myp.sx=(rnd()-0.5)*8"
        " myp.sy=(rnd()-1)*3"
        " "
        " myp.age=rnd(2)"
        " myp.size=1+rnd(4)"
        " myp.maxage=10+rnd(10)"
        " myp.blue=isblue"
        " myp.spark=true"
        " "
        " add(parts,myp)"
        " --end"
        "end"))
    (def-pico-function
      (name makespr)
      (params ())
      (line-range (452 470))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "myspr"))
      (body-lines
        "function makespr()"
        " local myspr={}"
        " myspr.x=0"
        " myspr.y=0"
        " myspr.sx=0"
        " myspr.sy=0"
        " "
        " myspr.flash=0"
        " myspr.shake=0"
        " "
        " myspr.aniframe=1"
        " myspr.spr=0"
        " myspr.sprw=1"
        " myspr.sprh=1"
        " myspr.colw=8"
        " myspr.colh=8"
        " "
        " return myspr"
        "end"))
    (def-pico-function
      (name doshake)
      (params ())
      (line-range (472 485))
      (api-calls (camera rnd))
      (called-functions ())
      (structured-ast
        (if-cond "shake>10")
        (if-cond "shake<1"))
      (body-lines
        "function doshake()"
        ""
        " local shakex=rnd(shake)-(shake/2)"
        " local shakey=rnd(shake)-(shake/2)"
        " "
        " camera(shakex,shakey)"
        " "
        " if shake>10 then"
        "  shake*=0.9"
        " else"
        "  shake-=1"
        "  if shake<1 then"
        "   shake=0"
        "  end"))
    (def-pico-function
      (name popfloat)
      (params (fltxt flx fly))
      (line-range (489 496))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (seq-block 8))
      (body-lines
        "function popfloat(fltxt,flx,fly)"
        " local fl={}"
        " fl.x=flx"
        " fl.y=fly"
        " fl.txt=fltxt"
        " fl.age=0"
        " add(floats,fl)"
        "end"))
    (def-pico-function
      (name cprint)
      (params (txt x y c))
      (line-range (498 500))
      (api-calls (print))
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (body-lines
        "function cprint(txt,x,y,c)"
        " print(txt,x-#txt*2,y,c)"
        "end"))
    (def-pico-function
      (name update_game)
      (params ())
      (line-range (506 515))
      (api-calls (btn))
      (called-functions ())
      (structured-ast
        (if-cond "btn(0"))
      (body-lines
        "function update_game()"
        " --controls"
        " ship.sx=0"
        " ship.sy=0"
        " ship.spr=2"
        " "
        " if btn(0) then"
        "  ship.sx=-2"
        "  ship.spr=1"
        " end"))
    (def-pico-function
      (name update_start)
      (params ())
      (line-range (727 732))
      (api-calls (btn))
      (called-functions (animatestars))
      (structured-ast
        (if-cond "btn(4"))
      (body-lines
        "function update_start()"
        " animatestars(0.4)"
        " "
        " if btn(4)==false and btn(5)==false then"
        "  btnreleased=true"
        " end"))
    (def-pico-function
      (name update_over)
      (params ())
      (line-range (742 745))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "t<lockout")
        (return-expr ""))
      (body-lines
        "function update_over()"
        " if t<lockout then"
        "  return"
        " end"))
    (def-pico-function
      (name update_win)
      (params ())
      (line-range (763 766))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "t<lockout")
        (return-expr ""))
      (body-lines
        "function update_win()"
        " if t<lockout then"
        "  return"
        " end"))
    (def-pico-function
      (name update_wavetext)
      (params ())
      (line-range (784 790))
      (api-calls ())
      (called-functions (spawnwave update_game))
      (structured-ast
        (if-cond "wavetime<=0"))
      (body-lines
        "function update_wavetext()"
        " update_game()"
        " wavetime-=1"
        " if wavetime<=0 then"
        "  mode=\"game\""
        "  spawnwave()"
        " end"))
    (def-pico-function
      (name draw_game)
      (params ())
      (line-range (795 801))
      (api-calls (cls))
      (called-functions ())
      (structured-ast
        (if-cond "flash>0"))
      (body-lines
        "function draw_game()"
        " if flash>0 then"
        "  flash-=1"
        "  cls(2)"
        " else"
        "  cls(0)"
        " end"))
    (def-pico-function
      (name makescore)
      (params (val))
      (line-range (938 941))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "val==0")
        (return-expr "\"0\""))
      (body-lines
        "function makescore(val)"
        " if val==0 then"
        "  return \"0\""
        " end"))
    (def-pico-function
      (name draw_start)
      (params ())
      (line-range (945 953))
      (api-calls (cls print rnd sin spr))
      (called-functions (starfield))
      (structured-ast
        (if-cond "sin(time("))
      (body-lines
        "function draw_start()"
        " cls(0)"
        " starfield()"
        " print(version,1,1,1)"
        ""
        " spr(21,peekerx,28+sin(time()/3.5)*4 )"
        " if sin(time()/3.5)>0.5 then"
        "  peekerx=30+rnd(60)"
        " end"))
    (def-pico-function
      (name draw_over)
      (params ())
      (line-range (971 980))
      (api-calls ())
      (called-functions (cprint draw_game makescore))
      (structured-ast
        (if-cond "score>highscore")
        (if-cond "t%4<2"))
      (body-lines
        "function draw_over()"
        " draw_game()"
        " cprint(\"game over\",64,40,8) "
        " "
        " cprint(\"score:\"..makescore(score),64,60,12)"
        " if score>highscore then"
        "  local c=7"
        "  if t%4<2 then"
        "   c=10"
        "  end"))
    (def-pico-function
      (name draw_win)
      (params ())
      (line-range (987 996))
      (api-calls ())
      (called-functions (cprint draw_game makescore))
      (structured-ast
        (if-cond "score>highscore")
        (if-cond "t%4<2"))
      (body-lines
        "function draw_win()"
        " draw_game()"
        " cprint(\"congratulations\",64,40,12)"
        " cprint(\"score:\"..makescore(score),64,60,12)"
        ""
        " if score>highscore then"
        "  local c=7"
        "  if t%4<2 then"
        "   c=10"
        "  end"))
    (def-pico-function
      (name draw_wavetext)
      (params ())
      (line-range (1003 1009))
      (api-calls ())
      (called-functions (blink cprint draw_game))
      (structured-ast
        (if-cond "wave==lastwave"))
      (body-lines
        "function draw_wavetext()"
        " draw_game()"
        " if wave==lastwave then"
        "  cprint(\"final wave!\",64,40,blink())"
        " else"
        "  cprint(\"wave \"..wave..\" of \"..lastwave,64,40,blink())"
        " end"))
    (def-pico-function
      (name spawnwave)
      (params ())
      (line-range (1014 1019))
      (api-calls (music sfx))
      (called-functions ())
      (structured-ast
        (if-cond "wave<lastwave"))
      (body-lines
        "function spawnwave()"
        " if wave<lastwave then"
        "  sfx(28)"
        " else"
        "  music(10)"
        " end"))
    (def-pico-function
      (name placens)
      (params (lvl))
      (line-range (1115 1122))
      (api-calls ())
      (called-functions (spawnen))
      (structured-ast
        (for-loop "y=1,4")
        (for-loop "x=1,10")
        (if-cond "myline[x]!=0"))
      (body-lines
        "function placens(lvl)"
        ""
        " for y=1,4 do"
        "  local myline=lvl[y]"
        "  for x=1,10 do"
        "   if myline[x]!=0 then"
        "    spawnen(myline[x],x*12-6,4+y*12,x*3)"
        "   end"))
    (def-pico-function
      (name nextwave)
      (params ())
      (line-range (1128 1140))
      (api-calls (music))
      (called-functions ())
      (structured-ast
        (if-cond "wave>lastwave")
        (if-cond "wave==1"))
      (body-lines
        "function nextwave()"
        " wave+=1"
        " "
        " if wave>lastwave then"
        "  mode=\"win\""
        "  lockout=t+30"
        "  music(4)"
        " else"
        "  if wave==1 then"
        "   music(0)"
        "  else"
        "   music(3)  "
        "  end"))
    (def-pico-function
      (name spawnen)
      (params (entype enx eny enwait))
      (line-range (1148 1207))
      (api-calls ())
      (called-functions (makespr))
      (structured-ast
        (if-cond "entype==nil or entype==1"))
      (body-lines
        "function spawnen(entype,enx,eny,enwait)"
        " local myen=makespr()"
        " myen.x=enx*1.25-16"
        " myen.y=eny-66"
        " "
        " myen.posx=enx"
        " myen.posy=eny"
        " "
        " myen.type=entype"
        " "
        " myen.wait=enwait"
        ""
        " myen.anispd=0.4"
        " "
        " myen.mission=\"flyin\""
        " "
        " if entype==nil or entype==1 then"
        "  -- green alien"
        "  myen.spr=21"
        "  myen.hp=3"
        "  myen.ani={21,22,23,24}"
        "  myen.score=1"
        " elseif entype==2 then"
        "  -- red flame guy"
        "  myen.spr=148"
        "  myen.hp=2"
        "  myen.ani={148,149}"
        "  myen.score=2"
        " elseif entype==3 then"
        "  -- spinning ship"
        "  myen.spr=184"
        "  myen.hp=4"))
    (def-pico-function
      (name doenemy)
      (params (myen))
      (line-range (1214 1218))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myen.wait>0")
        (return-expr ""))
      (body-lines
        "function doenemy(myen)"
        " if myen.wait>0 then"
        "  myen.wait-=1"
        "  return"
        " end"))
    (def-pico-function
      (name picktimer)
      (params ())
      (line-range (1322 1325))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "mode!=\"game\"")
        (return-expr ""))
      (body-lines
        "function picktimer()"
        " if mode!=\"game\" then"
        "  return"
        " end"))
    (def-pico-function
      (name pickattac)
      (params ())
      (line-range (1337 1350))
      (api-calls (flr min rnd))
      (called-functions ())
      (structured-ast
        (if-cond "myen==nil")
        (return-expr "end")
        (if-cond "myen.mission==\"protec\""))
      (body-lines
        "function pickattac()"
        " local maxnum=min(10,#enemies)"
        " local myindex=flr(rnd(maxnum))"
        " "
        " myindex=#enemies-myindex"
        " local myen=enemies[myindex]"
        " if myen==nil then return end"
        " "
        " if myen.mission==\"protec\" then"
        "  myen.mission=\"attac\""
        "  myen.anispd*=3"
        "  myen.wait=60"
        "  myen.shake=60"
        " end"))
    (def-pico-function
      (name pickfire)
      (params ())
      (line-range (1353 1362))
      (api-calls (all flr min rnd))
      (called-functions (firespread))
      (structured-ast
        (for-loop "myen in all(enemies)")
        (if-cond "myen.type==4 and myen.mission==\"protec\"")
        (if-cond "rnd(")
        (return-expr ""))
      (body-lines
        "function pickfire()"
        " local maxnum=min(10,#enemies)"
        " local myindex=flr(rnd(maxnum))"
        " "
        " for myen in all(enemies) do"
        "  if myen.type==4 and myen.mission==\"protec\" then"
        "   if rnd()<0.5 then"
        "    firespread(myen,12,1.3,rnd())"
        "    return"
        "   end"))
    (def-pico-function
      (name move)
      (params (obj))
      (line-range (1384 1387))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (body-lines
        "function move(obj)"
        " obj.x+=obj.sx"
        " obj.y+=obj.sy"
        "end"))
    (def-pico-function
      (name killen)
      (params (myen))
      (line-range (1389 1398))
      (api-calls (music sfx))
      (called-functions (boss5))
      (structured-ast
        (if-cond "myen.boss")
        (return-expr ""))
      (body-lines
        "function killen(myen)"
        " if myen.boss then"
        "  myen.mission=\"boss5\""
        "  myen.phbegin=t"
        "  myen.ghost=true"
        "  ebuls={}"
        "  music(-1)"
        "  sfx(51)"
        "  return"
        " end"))
    (def-pico-function
      (name dropickup)
      (params (pix piy))
      (line-range (1426 1433))
      (api-calls (add))
      (called-functions (makespr))
      (structured-ast
        (seq-block 8))
      (body-lines
        "function dropickup(pix,piy)"
        " local mypick=makespr()"
        " mypick.x=pix"
        " mypick.y=piy"
        " mypick.sy=0.75"
        " mypick.spr=48"
        " add(pickups,mypick)"
        "end"))
    (def-pico-function
      (name plogic)
      (params (mypick))
      (line-range (1435 1451))
      (api-calls (sfx))
      (called-functions (makescore popfloat smol_shwave))
      (structured-ast
        (if-cond "cher>=10")
        (if-cond "lives<4"))
      (body-lines
        "function plogic(mypick)"
        " cher+=1"
        " smol_shwave(mypick.x+4,mypick.y+4,14)"
        " if cher>=10 then"
        "  --get a life"
        "  if lives<4 then"
        "   lives+=1"
        "   sfx(31)"
        "   cher=0"
        "   popfloat(\"1up!\",mypick.x+4,mypick.y+4)"
        "  else"
        "   --points"
        "   score+=50"
        "   popfloat(makescore(50),mypick.x+4,mypick.y+4)"
        "   sfx(30)"
        "   cher=0"
        "  end"))
    (def-pico-function
      (name animate)
      (params (myen))
      (line-range (1457 1461))
      (api-calls (flr))
      (called-functions ())
      (structured-ast
        (if-cond "flr(myen.aniframe"))
      (body-lines
        "function animate(myen)"
        " myen.aniframe+=myen.anispd"
        " if flr(myen.aniframe) > #myen.ani then"
        "  myen.aniframe=1"
        " end"))
    (def-pico-function
      (name fire)
      (params (myen ang spd))
      (line-range (1467 1478))
      (api-calls ())
      (called-functions (makespr))
      (structured-ast
        (if-cond "myen.type==4"))
      (body-lines
        "function fire(myen,ang,spd)"
        " local myebul=makespr()"
        " myebul.x=myen.x+3"
        " myebul.y=myen.y+6"
        " "
        " if myen.type==4 then"
        "  myebul.x=myen.x+7"
        "  myebul.y=myen.y+13"
        " elseif myen.boss then"
        "  myebul.x=myen.x+15"
        "  myebul.y=myen.y+23 "
        " end"))
    (def-pico-function
      (name firespread)
      (params (myen num spd base))
      (line-range (1503 1506))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "base==nil"))
      (body-lines
        "function firespread(myen,num,spd,base)"
        " if base==nil then"
        "  base=0"
        " end"))
    (def-pico-function
      (name aimedfire)
      (params (myen spd))
      (line-range (1512 1519))
      (api-calls (atan2 cos sin))
      (called-functions (fire))
      (structured-ast
        (seq-block 8))
      (body-lines
        "function aimedfire(myen,spd)"
        " local myebul=fire(myen,0,spd)"
        " "
        " local ang=atan2((ship.y+4)-myebul.y,(ship.x+4)-myebul.x)"
        ""
        " myebul.sx=sin(ang)*spd"
        " myebul.sy=cos(ang)*spd "
        "end"))
    (def-pico-function
      (name cherbomb)
      (params ())
      (line-range (1521 1537))
      (api-calls (add cos sin))
      (called-functions (makespr))
      (structured-ast
        (for-loop "i=0,cher*2"))
      (body-lines
        "function cherbomb()"
        " local spc=0.25/(cher*2)"
        " "
        " for i=0,cher*2 do"
        "  local ang=0.375+spc*i"
        "  "
        "  local newbul=makespr()"
        "  newbul.x=ship.x"
        "  newbul.y=ship.y-3"
        "  newbul.spr=17"
        "  newbul.dmg=3"
        "  "
        "  newbul.sx=sin(ang)*4"
        "  newbul.sy=cos(ang)*4"
        " "
        "  add(buls,newbul)"
        " end"))
    (def-pico-function
      (name boss1)
      (params (myen))
      (line-range (1550 1556))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myen.sx==0 or myen.x>=93"))
      (body-lines
        "function boss1(myen)"
        " -- movement"
        " local spd=2"
        " "
        " if myen.sx==0 or myen.x>=93 then"
        "  myen.sx=-spd"
        " end"))
    (def-pico-function
      (name boss2)
      (params (myen))
      (line-range (1576 1584))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myen.subphase==1")
        (if-cond "myen.x<=4"))
      (body-lines
        "function boss2(myen)"
        " local spd=1.5"
        " "
        " -- movement"
        " if myen.subphase==1 then"
        "  myen.sx=-spd"
        "  if myen.x<=4 then"
        "   myen.subphase=2"
        "  end"))
    (def-pico-function
      (name boss3)
      (params (myen))
      (line-range (1615 1621))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myen.sx==0 or myen.x>=93"))
      (body-lines
        "function boss3(myen)"
        " -- movement"
        " local spd=0.5"
        " "
        " if myen.sx==0 or myen.x>=93 then"
        "  myen.sx=-spd"
        " end"))
    (def-pico-function
      (name boss4)
      (params (myen))
      (line-range (1640 1648))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "myen.subphase==1")
        (if-cond "myen.x>=91"))
      (body-lines
        "function boss4(myen)"
        " local spd=1.5"
        " "
        " -- movement"
        " if myen.subphase==1 then"
        "  myen.sx=spd"
        "  if myen.x>=91 then"
        "   myen.subphase=2"
        "  end"))
    (def-pico-function
      (name boss5)
      (params (myen))
      (line-range (1688 1696))
      (api-calls (rnd sfx))
      (called-functions (explode))
      (structured-ast
        (if-cond "t%8==0"))
      (body-lines
        "function boss5(myen)"
        " myen.shake=10"
        " myen.flash=10 "
        " "
        " if t%8==0 then"
        "  explode(myen.x+rnd(32),myen.y+rnd(24))"
        "  sfx(2)"
        "  shake=2"
        " end")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id 0 #:grid (0 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00700700" "00077000" "00077000" "00700700" "00000000" "00000000"))
      (def-pico-sprite #:id 1 #:grid (1 0) #:nonzero-pixels 37 #:rows ("00022000" "00288200" "00288200" "00288e20" "027c8820" "02118820" "02558220" "00299200"))
      (def-pico-sprite #:id 2 #:grid (2 0) #:nonzero-pixels 42 #:rows ("00022000" "00288200" "00288200" "02e88e20" "2e87c8e2" "28811882" "02855820" "00299200"))
      (def-pico-sprite #:id 3 #:grid (3 0) #:nonzero-pixels 37 #:rows ("00022000" "00288200" "00288200" "02e88200" "02887c20" "02881120" "02285520" "00299200"))
      (def-pico-sprite #:id 5 #:grid (5 0) #:nonzero-pixels 12 #:rows ("00000000" "00077000" "00c77c00" "00cccc00" "000cc000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 6 #:grid (6 0) #:nonzero-pixels 10 #:rows ("00000000" "00077000" "00077000" "000cc000" "000cc000" "000cc000" "00000000" "00000000"))
      (def-pico-sprite #:id 7 #:grid (7 0) #:nonzero-pixels 12 #:rows ("00000000" "00077000" "00c77c00" "00cccc00" "000cc000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 8 #:grid (8 0) #:nonzero-pixels 14 #:rows ("00000000" "00c77c00" "0cccccc0" "00cccc00" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 9 #:grid (9 0) #:nonzero-pixels 12 #:rows ("00000000" "00077000" "00c77c00" "00cccc00" "000cc000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 10 #:grid (10 0) #:nonzero-pixels 64 #:rows ("cccccccc" "cccccccc" "cccccccc" "cccc6ccc" "ccc67ccc" "ccc77ccc" "ccc77ccc" "ccc77ccc"))
      (def-pico-sprite #:id 11 #:grid (11 0) #:nonzero-pixels 64 #:rows ("cccccccc" "cccccccc" "77cccccc" "77cccccc" "77cccccc" "77ccccc7" "77ccccc7" "77cccc67"))
      (def-pico-sprite #:id 12 #:grid (12 0) #:nonzero-pixels 64 #:rows ("c666cccc" "c777cccc" "67776ccc" "77777ccc" "77c77ccc" "76c776cc" "766777cc" "777777cc"))
      (def-pico-sprite #:id 13 #:grid (13 0) #:nonzero-pixels 64 #:rows ("7777766c" "7777776c" "ccc677cc" "ccc776cc" "cc677ccc" "cc776ccc" "c677cccc" "c776cccc"))
      (def-pico-sprite #:id 14 #:grid (14 0) #:nonzero-pixels 64 #:rows ("6ccccccc" "776ccccc" "c77cc777" "c6777776" "cc77776c" "ccc776cc" "ccc77ccc" "ccc77ccc"))
      (def-pico-sprite #:id 15 #:grid (15 0) #:nonzero-pixels 56 #:rows ("ccccccc0" "ccccccc0" "ccccccc0" "cc6cccc0" "cc76ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0"))
      (def-pico-sprite #:id 16 #:grid (0 1) #:nonzero-pixels 40 #:rows ("09999000" "99779900" "9a77a900" "9a77a900" "9a77a900" "99aa9900" "09aa9000" "00990000"))
      (def-pico-sprite #:id 17 #:grid (1 1) #:nonzero-pixels 52 #:rows ("00999900" "09aaaa90" "9aa77aa9" "9a7777a9" "9a7777a9" "9aa77aa9" "09aaaa90" "00999900"))
      (def-pico-sprite #:id 21 #:grid (5 1) #:nonzero-pixels 44 #:rows ("03300330" "33b33b33" "3bbbbbb3" "3b7717b3" "0b7117b0" "00377300" "03033030" "03000030"))
      (def-pico-sprite #:id 22 #:grid (6 1) #:nonzero-pixels 44 #:rows ("03300330" "33b33b33" "3bbbbbb3" "3b7717b3" "0b7117b0" "00377300" "03033030" "30000003"))
      (def-pico-sprite #:id 23 #:grid (7 1) #:nonzero-pixels 44 #:rows ("03300330" "33b33b33" "3bbbbbb3" "3b7717b3" "0b7117b0" "00377300" "03033030" "03000030"))
      (def-pico-sprite #:id 24 #:grid (8 1) #:nonzero-pixels 46 #:rows ("03300330" "33b33b33" "3bbbbbb3" "3b7717b3" "0b7117b0" "00377300" "03033030" "03300330"))
      (def-pico-sprite #:id 26 #:grid (10 1) #:nonzero-pixels 64 #:rows ("ccc77ccc" "ccc77ccc" "ccc77ccc" "ccc77ccc" "ccc77ccc" "ccc77ccc" "ccc77ccc" "ccc676cc"))
      (def-pico-sprite #:id 27 #:grid (11 1) #:nonzero-pixels 64 #:rows ("77666c77" "77777677" "7666666c" "cccccccc" "cccccccc" "777777cc" "7777777c" "77ccc777"))
      (def-pico-sprite #:id 28 #:grid (12 1) #:nonzero-pixels 64 #:rows ("7666776c" "cccc676c" "cccccccc" "cccccccc" "c66677cc" "c77777cc" "c676cccc" "c676cccc"))
      (def-pico-sprite #:id 29 #:grid (13 1) #:nonzero-pixels 64 #:rows ("7777777c" "7777777c" "cccccccc" "cccccccc" "77cccc66" "776ccc77" "677cc677" "c77cc776"))
      (def-pico-sprite #:id 30 #:grid (14 1) #:nonzero-pixels 64 #:rows ("ccc776cc" "ccc776cc" "ccc66ccc" "cccccccc" "6cc666cc" "6c77777c" "cc77667c" "c677cccc"))
      (def-pico-sprite #:id 31 #:grid (15 1) #:nonzero-pixels 56 #:rows ("cc77ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0" "cc77ccc0"))
      (def-pico-sprite #:id 32 #:grid (0 2) #:nonzero-pixels 24 #:rows ("00ee0000" "0e22e000" "e2e82e00" "e2882e00" "0e22e000" "00ee0000" "00000000" "00000000"))
      (def-pico-sprite #:id 33 #:grid (1 2) #:nonzero-pixels 24 #:rows ("00ee0000" "0e88e000" "e87e8e00" "e8ee8e00" "0e88e000" "00ee0000" "00000000" "00000000"))
      (def-pico-sprite #:id 34 #:grid (2 2) #:nonzero-pixels 24 #:rows ("00770000" "07cc7000" "7c77c700" "7c77c700" "07cc7000" "00770000" "00000000" "00000000"))
      (def-pico-sprite #:id 37 #:grid (5 2) #:nonzero-pixels 40 #:rows ("08800880" "88888888" "88888888" "88888888" "08888880" "00888800" "00088000" "00000000"))
      (def-pico-sprite #:id 38 #:grid (6 2) #:nonzero-pixels 18 #:rows ("08800880" "80088008" "80000008" "80000008" "08000080" "00800800" "00088000" "00000000")))
    (gff-flags)
    (map-rows)
    (sfx-tracks
      (def-pico-sfx #:id 0 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 25)
      (def-pico-sfx #:id 1 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 17)
      (def-pico-sfx #:id 2 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 3 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 2)
      (def-pico-sfx #:id 4 #:editor-mode 0 #:speed 6 #:loop (0 0) #:active-notes 28)
      (def-pico-sfx #:id 5 #:editor-mode 0 #:speed 6 #:loop (0 0) #:active-notes 28)
      (def-pico-sfx #:id 6 #:editor-mode 0 #:speed 6 #:loop (0 0) #:active-notes 28)
      (def-pico-sfx #:id 7 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 8 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 9 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 10 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 11 #:editor-mode 9 #:speed 13 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 12 #:editor-mode 5 #:speed 13 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 13 #:editor-mode 1 #:speed 13 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 14 #:editor-mode 77 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 15 #:editor-mode 77 #:speed 16 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 16 #:editor-mode 1 #:speed 15 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 17 #:editor-mode 5 #:speed 15 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 18 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 19 #:editor-mode 81 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 20 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 21 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 22 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 14)
      (def-pico-sfx #:id 23 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 14)
      (def-pico-sfx #:id 24 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 11)
      (def-pico-sfx #:id 25 #:editor-mode 81 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 26 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 27 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 11)
      (def-pico-sfx #:id 28 #:editor-mode 17 #:speed 5 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 29 #:editor-mode 72 #:speed 2 #:loop (0 0) #:active-notes 6)
      (def-pico-sfx #:id 30 #:editor-mode 8 #:speed 12 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 31 #:editor-mode 0 #:speed 10 #:loop (0 0) #:active-notes 11))
    (music-patterns
      (def-pico-music #:pattern 0 #:flags 4 #:channels (4 5 6 68))
      (def-pico-music #:pattern 1 #:flags 0 #:channels (7 8 71 73))
      (def-pico-music #:pattern 2 #:flags 4 #:channels (9 10 72 74))
      (def-pico-music #:pattern 3 #:flags 4 #:channels (11 12 13 68))
      (def-pico-music #:pattern 4 #:flags 0 #:channels (14 8 67 68))
      (def-pico-music #:pattern 5 #:flags 4 #:channels (15 10 67 68))
      (def-pico-music #:pattern 6 #:flags 4 #:channels (16 17 78 68))
      (def-pico-music #:pattern 7 #:flags 1 #:channels (18 19 20 21))
      (def-pico-music #:pattern 8 #:flags 0 #:channels (22 19 20 23))
      (def-pico-music #:pattern 9 #:flags 2 #:channels (24 25 26 27))
      (def-pico-music #:pattern 10 #:flags 0 #:channels (36 37 104 68))
      (def-pico-music #:pattern 11 #:flags 1 #:channels (38 39 40 68))
      (def-pico-music #:pattern 12 #:flags 0 #:channels (38 40 41 102))
      (def-pico-music #:pattern 13 #:flags 0 #:channels (38 39 42 101))
      (def-pico-music #:pattern 14 #:flags 0 #:channels (38 42 43 101))
      (def-pico-music #:pattern 15 #:flags 0 #:channels (38 39 44 68))
      (def-pico-music #:pattern 16 #:flags 0 #:channels (38 41 45 68))
      (def-pico-music #:pattern 17 #:flags 0 #:channels (38 39 44 68))
      (def-pico-music #:pattern 18 #:flags 0 #:channels (38 42 46 68))
      (def-pico-music #:pattern 19 #:flags 0 #:channels (40 41 47 68))
      (def-pico-music #:pattern 20 #:flags 0 #:channels (40 41 48 68))
      (def-pico-music #:pattern 21 #:flags 0 #:channels (39 43 47 68))
      (def-pico-music #:pattern 22 #:flags 2 #:channels (37 36 49 68))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      "-- cherry bomb"
      "-- by lazy devs"
      ""
      "function _init()"
      " --this will clear the screen"
      " cls(0)"
      " "
      " cartdata(\"cherrybomb\")"
      " highscore=dget(0)"
      " "
      " version=\"v1\""
      " "
      " startscreen()"
      " blinkt=1"
      " t=0"
      " lockout=0"
      " "
      " shake=0"
      " flash=0"
      ""
      " debug=\"\""
      " "
      " peekerx=64"
      " "
      " -- logo ani --"
      "\tfadetable={{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},{1,1,129,129,129,129,129,129,129,129,0,0,0,0,0},{2,2,2,130,130,130,130,130,128,128,128,128,128,0,0},{3,3,3,131,131,131,131,129,129,129,129,129,0,0,0},{4,4,132,132,132,132,132,132,130,128,128,128,128,0,0},{5,5,133,133,133,133,130,130,128,128,128,128,128,0,0},{6,6,134,13,13,13,141,5,5,5,133,130,128,128,0},{7,6,6,6,134,134,134,134,5,5,5,133,130,128,0},{8,8,136,136,136,136,132,132,132,130,128,128,128,128,0},{9,9,9,4,4,4,4,132,132,132,128,128,128,128,0},{10,10,138,138,138,4,4,4,132,132,133,128,128,128,0},{11,139,139,139,139,3,3,3,3,129,129,129,0,0,0},{12,12,12,140,140,140,140,131,131,131,1,129,129,129,0},{13,13,141,141,5,5,5,133,133,130,129,129,128,128,0},{14,14,14,134,134,141,141,2,2,133,130,130,128,128,0},{15,143,143,134,134,134,134,5,5,5,133,133,128,128,0}}"
      ""
      " cls(12)"
      " spr(10,40,34,6,5)"
      " cprint(\"a lazy devs game\", 64,80,7)"
      " cprint(\"by krystian majewski\", 64,86,7)"
      " "
      " fadeperc=1"
      " "
      " repeat"
      "  dofade()"
      "  fadeperc-=0.07"
      "  flip()"
      " until( fadeperc<=0 )"
      " "
      " fadeperc=0"
      " dofade()"
      " for i=0,30 do"
      "  flip()"
      " end"
      " "
      " repeat"
      "  dofade()"
      "  fadeperc+=0.07"
      "  flip()"
      " until( fadeperc>=1 )"
      " fadeperc=0"
      " cls()"
      " dofade()"
      " for i=0,10 do"
      "  flip()"
      " end"
      " "
      "end"
      ""
      "function dofade()"
      " fadeperc=min(fadeperc,1)"
      " for c=0,15 do"
      "  pal(c,fadetable[c+1][flr(fadeperc*16+1)],1)"
      " end"
      "end"
      ""
      "function _update() "
      " t+=1"
      " "
      " blinkt+=1"
      " "
      " if mode==\"game\" then"
      "  update_game()"
      " elseif mode==\"start\" then"
      "  update_start()"
      " elseif mode==\"wavetext\" then"
      "  update_wavetext()"
      " elseif mode==\"over\" then"
      "  update_over()"
      " elseif mode==\"win\" then"
      "  update_win()"
      " end"
      " "
      "end"
      ""
      "function _draw()"
      " doshake()"
      " "
      " if mode==\"game\" then"
      "  draw_game()"
      " elseif mode==\"start\" then"
      "  draw_start()"
      " elseif mode==\"wavetext\" then"
      "  draw_wavetext()"
      " elseif mode==\"over\" then"
      "  draw_over()"
      " elseif mode==\"win\" then"
      "  draw_win()"
      " end"
      " "
      " camera()"
      " print(debug,2,9,7)"
      ""
      "end"
      ""
      "function startscreen()"
      " makestars()"
      " mode=\"start\""
      " music(7)"
      "end"
      ""
      "function startgame()"
      " t=0"
      " wave=0"
      " lastwave=9"
      " nextwave()"
      " "
      " ship=makespr()"
      " ship.x=60"
      " ship.y=90"
      " ship.sx=0"
      " ship.sy=0"
      " ship.spr=2"
      "   "
      " flamespr=5"
      " "
      " bultimer=0"
      " "
      " muzzle=0"
      " "
      " score=0"
      " cher=0"
      " "
      " lives=4"
      " invul=0"
      " "
      " attacfreq=60"
      " firefreq=20"
      " nextfire=0"
      " "
      " makestars()"
      "  "
      " buls={}"
      " ebuls={}"
      " "
      " enemies={}"
      " "
      " parts={}"
      " "
      " shwaves={}"
      " "
      " pickups={}"
      " "
      " floats={}"
      "end"
      ""
      "-->8"
      "-- tools"
      ""
      "function makestars()"
      " stars={} "
      " for i=1,100 do"
      "  local newstar={}"
      "  newstar.x=flr(rnd(128))"
      "  newstar.y=flr(rnd(128))"
      "  newstar.spd=rnd(1.5)+0.5"
      "  add(stars,newstar)"
      " end "
      "end"
      ""
      "function starfield()"
      " "
      " for i=1,#stars do"
      "  local mystar=stars[i]"
      "  local scol=6"
      "  "
      "  if mystar.spd<1 then"
      "   scol=1"
      "  elseif mystar.spd<1.5 then"
      "   scol=13"
      "  end   "
      "  "
      "  pset(mystar.x,mystar.y,scol)"
      " end"
      "end"
      ""
      "function animatestars(spd)"
      " if spd==nil then"
      "  spd=1"
      " end"
      " "
      " for i=1,#stars do"
      "  local mystar=stars[i]"
      "  mystar.y=mystar.y+mystar.spd*spd"
      "  if mystar.y>128 then"
      "   mystar.y=mystar.y-128"
      "  end"
      " end"
      ""
      "end"
      ""
      "function blink()"
      " local banim={5,5,5,5,5,5,5,5,5,5,5,6,6,7,7,6,6,5}"
      " "
      " if blinkt>#banim then"
      "  blinkt=1"
      " end"
      ""
      " return banim[blinkt]"
      "end"
      ""
      "function drwoutline(myspr)"
      " spr(myspr.spr,myspr.x+1,myspr.y,myspr.sprw,myspr.sprh)"
      " spr(myspr.spr,myspr.x-1,myspr.y,myspr.sprw,myspr.sprh)"
      " spr(myspr.spr,myspr.x,myspr.y+1,myspr.sprw,myspr.sprh)"
      " spr(myspr.spr,myspr.x,myspr.y-1,myspr.sprw,myspr.sprh)"
      "end"
      ""
      "function drwmyspr(myspr)"
      " local sprx=myspr.x"
      " local spry=myspr.y"
      " "
      " if myspr.shake>0 then"
      "  myspr.shake-=1"
      "  if t%4<2 then"
      "   sprx+=1"
      "  end"
      " end"
      " if myspr.bulmode then"
      "  sprx-=2"
      "  spry-=2"
      " end"
      " "
      " spr(myspr.spr,sprx,spry,myspr.sprw,myspr.sprh)"
      "end"
      ""
      "function col(a,b)"
      " if a.ghost or b.ghost then "
      "  return false"
      " end"
      ""
      " local a_left=a.x"
      " local a_top=a.y"
      " local a_right=a.x+a.colw-1"
      " local a_bottom=a.y+a.colh-1"
      " "
      " local b_left=b.x"
      " local b_top=b.y"
      " local b_right=b.x+b.colw-1"
      " local b_bottom=b.y+b.colh-1"
      ""
      " if a_top>b_bottom then return false end"
      " if b_top>a_bottom then return false end"
      " if a_left>b_right then return false end"
      " if b_left>a_right then return false end"
      " "
      " return true"
      "end"
      ""
      "function explode(expx,expy,isblue)"
      " "
      " local myp={}"
      " myp.x=expx"
      " myp.y=expy"
      " "
      " myp.sx=0"
      " myp.sy=0"
      " "
      " myp.age=0"
      " myp.size=10"
      " myp.maxage=0"
      " myp.blue=isblue"
      " "
      " add(parts,myp)"
      "\t  "
      " for i=1,30 do"
      "\t local myp={}"
      "\t myp.x=expx"
      "\t myp.y=expy"
      "\t "
      "\t myp.sx=rnd()*6-3"
      "\t myp.sy=rnd()*6-3"
      "\t "
      "\t myp.age=rnd(2)"
      "\t myp.size=1+rnd(4)"
      "\t myp.maxage=10+rnd(10)"
      "\t myp.blue=isblue"
      "\t "
      "\t add(parts,myp)"
      " end"
      " "
      " for i=1,20 do"
      "\t local myp={}"
      "\t myp.x=expx"
      "\t myp.y=expy"
      "\t "
      "\t myp.sx=(rnd()-0.5)*10"
      "\t myp.sy=(rnd()-0.5)*10"
      "\t "
      "\t myp.age=rnd(2)"
      "\t myp.size=1+rnd(4)"
      "\t myp.maxage=10+rnd(10)"
      "\t myp.blue=isblue"
      "\t myp.spark=true"
      "\t "
      "\t add(parts,myp)"
      " end"
      " "
      " big_shwave(expx,expy)"
      " "
      "end"
      ""
      "function bigexplode(expx,expy)"
      " "
      " local myp={}"
      " myp.x=expx"
      " myp.y=expy"
      " "
      " myp.sx=0"
      " myp.sy=0"
      " "
      " myp.age=0"
      " myp.size=25"
      " myp.maxage=0"
      " "
      " add(parts,myp)"
      "\t  "
      " for i=1,60 do"
      "\t local myp={}"
      "\t myp.x=expx"
      "\t myp.y=expy"
      "\t "
      "\t myp.sx=rnd()*12-6"
      "\t myp.sy=rnd()*12-6"
      "\t "
      "\t myp.age=rnd(2)"
      "\t myp.size=1+rnd(6)"
      "\t myp.maxage=20+rnd(20)"
      "\t "
      "\t add(parts,myp)"
      " end"
      " "
      " for i=1,100 do"
      "\t local myp={}"
      "\t myp.x=expx"
      "\t myp.y=expy"
      "\t "
      "\t myp.sx=(rnd()-0.5)*30"
      "\t myp.sy=(rnd()-0.5)*30"
      "\t "
      "\t myp.age=rnd(2)"
      "\t myp.size=1+rnd(4)"
      "\t myp.maxage=20+rnd(20)"
      "\t myp.spark=true"
      "\t "
      "\t add(parts,myp)"
      " end"
      " "
      " big_shwave(expx,expy)"
      " "
      "end"
      ""
      "function page_red(page)"
      " local col=7"
      " "
      " if page>5 then"
      "  col=10"
      " end"
      " if page>7 then"
      "  col=9"
      " end"
      " if page>10 then"
      "  col=8"
      " end"
      " if page>12 then"
      "  col=2"
      " end"
      " if page>15 then"
      "  col=5"
      " end"
      " "
      " return col"
      "end"
      ""
      "function page_blue(page)"
      " local col=7"
      " "
      " if page>5 then"
      "  col=6"
      " end"
      " if page>7 then"
      "  col=12"
      " end"
      " if page>10 then"
      "  col=13"
      " end"
      " if page>12 then"
      "  col=1"
      " end"
      " if page>15 then"
      "  col=1"
      " end"
      " "
      " return col"
      "end"
      ""
      "function smol_shwave(shx,shy,shcol)"
      " if shcol==nil then"
      "  shcol=9"
      " end "
      " local mysw={}"
      " mysw.x=shx"
      " mysw.y=shy"
      " mysw.r=3"
      " mysw.tr=6"
      " mysw.col=shcol"
      " mysw.speed=1"
      " add(shwaves,mysw)"
      "end"
      ""
      "function big_shwave(shx,shy)"
      " local mysw={}"
      " mysw.x=shx"
      " mysw.y=shy"
      " mysw.r=3"
      " mysw.tr=25"
      " mysw.col=7"
      " mysw.speed=3.5"
      " add(shwaves,mysw)"
      "end"
      ""
      "function smol_spark(sx,sy)"
      " --for i=1,2 do"
      " local myp={}"
      " myp.x=sx"
      " myp.y=sy"
      " "
      " myp.sx=(rnd()-0.5)*8"
      " myp.sy=(rnd()-1)*3"
      " "
      " myp.age=rnd(2)"
      " myp.size=1+rnd(4)"
      " myp.maxage=10+rnd(10)"
      " myp.blue=isblue"
      " myp.spark=true"
      " "
      " add(parts,myp)"
      " --end"
      "end"
      ""
      "function makespr()"
      " local myspr={}"
      " myspr.x=0"
      " myspr.y=0"
      " myspr.sx=0"
      " myspr.sy=0"
      " "
      " myspr.flash=0"
      " myspr.shake=0"
      " "
      " myspr.aniframe=1"
      " myspr.spr=0"
      " myspr.sprw=1"
      " myspr.sprh=1"
      " myspr.colw=8"
      " myspr.colh=8"
      " "
      " return myspr"
      "end"
      ""
      "function doshake()"
      ""
      " local shakex=rnd(shake)-(shake/2)"
      " local shakey=rnd(shake)-(shake/2)"
      " "
      " camera(shakex,shakey)"
      " "
      " if shake>10 then"
      "  shake*=0.9"
      " else"
      "  shake-=1"
      "  if shake<1 then"
      "   shake=0"
      "  end"
      " end"
      "end"
      ""
      "function popfloat(fltxt,flx,fly)"
      " local fl={}"
      " fl.x=flx"
      " fl.y=fly"
      " fl.txt=fltxt"
      " fl.age=0"
      " add(floats,fl)"
      "end"
      ""
      "function cprint(txt,x,y,c)"
      " print(txt,x-#txt*2,y,c)"
      "end"
      ""
      ""
      "-->8"
      "--update"
      ""
      "function update_game()"
      " --controls"
      " ship.sx=0"
      " ship.sy=0"
      " ship.spr=2"
      " "
      " if btn(0) then"
      "  ship.sx=-2"
      "  ship.spr=1"
      " end"
      " if btn(1) then"
      "  ship.sx=2"
      "  ship.spr=3"
      " end"
      " if btn(2) then"
      "  ship.sy=-2"
      " end"
      " if btn(3) then"
      "  ship.sy=2"
      " end"
      "  "
      " if btnp(4) then"
      "  if cher>0 then"
      "   cherbomb()"
      "   cher=0"
      "  else"
      "   sfx(32)"
      "  end"
      " end"
      " "
      " if btn(5) then"
      "  if bultimer<=0 then"
      "\t  local newbul=makespr()"
      "\t  newbul.x=ship.x+1"
      "\t  newbul.y=ship.y-3"
      "\t  newbul.spr=16"
      "\t  newbul.colw=6"
      "\t  newbul.sy=-4"
      "\t  newbul.dmg=1"
      "\t  add(buls,newbul)"
      "\t  "
      "\t  sfx(0)"
      "\t  muzzle=5"
      "\t  bultimer=4"
      "  end"
      " end"
      " bultimer-=1"
      " "
      " --moving the ship"
      " ship.x+=ship.sx"
      " ship.y+=ship.sy"
      " "
      " --checking if we hit the edge"
      " if ship.x>120 then"
      "  ship.x=120"
      " end"
      " if ship.x<0 then"
      "  ship.x=0"
      " end"
      " if ship.y<0 then"
      "  ship.y=0"
      " end"
      " if ship.y>120 then"
      "  ship.y=120"
      " end"
      " "
      " --move the bullets"
      " for mybul in all(buls) do"
      "  move(mybul)"
      "  if mybul.y<-8 then"
      "   del(buls,mybul)"
      "  end"
      " end"
      " "
      " --move the ebuls"
      " for myebul in all(ebuls) do"
      "  move(myebul)"
      "  animate(myebul)"
      "  if myebul.y>128 or myebul.x<-8 or myebul.x>128 or myebul.y<-8 then"
      "   del(ebuls,myebul)"
      "  end"
      " end "
      " "
      " --move the pickups"
      " for mypick in all(pickups) do"
      "  move(mypick)"
      "  if mypick.y>128 then"
      "   del(pickups,mypick)"
      "  end"
      " end "
      " "
      " --moving enemies "
      " for myen in all(enemies) do"
      "  --enemy mission"
      "  doenemy(myen)"
      "  "
      "  --enemy animation"
      "  animate(myen)"
      "    "
      "  --enemy leaving screen"
      "  if myen.mission!=\"flyin\" then "
      "   if myen.y>128 or myen.x<-8 or myen.x>128 then"
      "    del(enemies,myen)"
      "   end"
      "  end"
      " end"
      " "
      " --collision enemy x bullets"
      " for myen in all(enemies) do"
      "  for mybul in all(buls) do"
      "   if col(myen,mybul) then"
      "    del(buls,mybul)"
      "    smol_shwave(mybul.x+4,mybul.y+4)"
      "    smol_spark(myen.x+4,myen.y+4)"
      "    if myen.mission!=\"flyin\" then"
      "     myen.hp-=mybul.dmg"
      "    end"
      "    sfx(3)"
      "    if myen.boss then"
      "     myen.flash=5"
      "    else"
      "     myen.flash=2"
      "    end"
      "    if myen.hp<=0 then"
      "     killen(myen)"
      "    end"
      "   end"
      "  end"
      " end"
      " "
      " --collision ebuls x bullets"
      " for mybul in all(buls) do"
      "  if mybul.spr==17 then"
      "\t  for myebul in all(ebuls) do"
      "\t   if col(myebul,mybul) then"
      "\t    del(ebuls,myebul)"
      "\t    score+=5"
      "\t    smol_shwave(ebuls.x,ebuls.y,8)"
      "\t   end"
      "\t  end"
      "  end"
      " end"
      " "
      " --collision ship x enemies"
      " if invul<=0 then"
      "\t for myen in all(enemies) do"
      "\t  if col(myen,ship) then"
      "    explode(ship.x+4,ship.y+4,true)"
      "\t   lives-=1"
      "\t   sfx(1)"
      "\t   shake=12"
      "\t   invul=60"
      "    ship.x=60"
      "    ship.y=100"
      "    flash=3"
      "\t  end"
      "\t end"
      " else"
      "  invul-=1"
      " end"
      " "
      " --collision ship x ebuls"
      " if invul<=0 then"
      "\t for myebul in all(ebuls) do"
      "\t  if col(myebul,ship) then"
      "    explode(ship.x+4,ship.y+4,true)"
      "\t   lives-=1"
      "\t   shake=12"
      "\t   sfx(1)"
      "\t   invul=60"
      "    ship.x=60"
      "    ship.y=100"
      "    flash=3"
      "\t  end"
      "\t end"
      " end"
      " "
      " --collision pickup x ship"
      " for mypick in all(pickups) do"
      "  if col(mypick,ship) then"
      "   del(pickups,mypick)"
      "   plogic(mypick)"
      "  end"
      " end"
      " "
      " "
      " if lives<=0 then"
      "  mode=\"over\""
      "  lockout=t+30"
      "  music(6)"
      "  return"
      " end"
      " "
      " --picking"
      " picktimer()"
      " "
      " --animate flame"
      " flamespr=flamespr+1"
      " if flamespr>9 then"
      "  flamespr=5"
      " end"
      " "
      " --animate mullze flash"
      " if muzzle>0 then"
      "  muzzle=muzzle-1"
      " end"
      "  "
      " if mode==\"wavetext\" then"
      "  animatestars(2)"
      " else"
      "  animatestars()"
      " end"
      " "
      " --check if wave over"
      " if mode==\"game\" and #enemies==0 then"
      "  ebuls={}"
      "  nextwave()"
      " end"
      " "
      "end"
      ""
      "function update_start()"
      " animatestars(0.4)"
      " "
      " if btn(4)==false and btn(5)==false then"
      "  btnreleased=true"
      " end"
      ""
      " if btnreleased then"
      "  if btnp(4) or btnp(5) then"
      "   startgame()"
      "   btnreleased=false"
      "  end"
      " end"
      "end"
      ""
      "function update_over()"
      " if t<lockout then"
      "  return"
      " end"
      " "
      " if btn(4)==false and btn(5)==false then"
      "  btnreleased=true"
      " end"
      ""
      " if btnreleased then"
      "  if btnp(4) or btnp(5) then"
      "   if score>highscore then"
      "    highscore=score"
      "    dset(0,score)"
      "   end"
      "   startscreen()"
      "   btnreleased=false"
      "  end"
      " end"
      "end"
      ""
      "function update_win()"
      " if t<lockout then"
      "  return"
      " end"
      " "
      " if btn(4)==false and btn(5)==false then"
      "  btnreleased=true"
      " end"
      ""
      " if btnreleased then"
      "  if btnp(4) or btnp(5) then"
      "   if score>highscore then"
      "    highscore=score"
      "    dset(0,score)"
      "   end"
      "   startscreen()"
      "   btnreleased=false"
      "  end"
      " end"
      "end"
      ""
      "function update_wavetext()"
      " update_game()"
      " wavetime-=1"
      " if wavetime<=0 then"
      "  mode=\"game\""
      "  spawnwave()"
      " end"
      "end"
      "-->8"
      "-- draw"
      ""
      "function draw_game()"
      " if flash>0 then"
      "  flash-=1"
      "  cls(2)"
      " else"
      "  cls(0)"
      " end"
      " "
      " starfield()"
      ""
      " if lives>0 then"
      "\t if invul<=0 then"
      "\t  drwmyspr(ship)"
      "\t  spr(flamespr,ship.x,ship.y+8)"
      "\t else"
      "\t  --invul state"
      "\t  if sin(t/5)<0.1 then"
      "\t   drwmyspr(ship)"
      "\t   spr(flamespr,ship.x,ship.y+8)"
      "\t  end"
      "\t end"
      " end"
      " "
      " --drawing pickups"
      " for mypick in all(pickups) do"
      "  local mycol=7"
      "  if t%4<2 then"
      "   mycol=14"
      "  end"
      "  for i=1,15 do"
      "   pal(i,mycol)"
      "  end"
      "  drwoutline(mypick)"
      "  pal()"
      "  drwmyspr(mypick)"
      " end"
      " "
      " --drawing enemies"
      " for myen in all(enemies) do"
      "  if myen.flash>0 then"
      "   if t%4<2 then"
      "    pal(3,8)"
      "    pal(11,14)"
      "   end"
      "   myen.flash-=1"
      "   if myen.boss then"
      "    myen.spr=80"
      "   else"
      "    for i=1,15 do"
      "     pal(i,7)"
      "    end"
      "   end"
      "  end"
      "  drwmyspr(myen)"
      "  pal()"
      " end"
      "  "
      " --drawing bullets"
      " for mybul in all(buls) do"
      "  drwmyspr(mybul)"
      " end"
      " "
      " if muzzle>0 then"
      "  circfill(ship.x+3,ship.y-2,muzzle,7)"
      "  circfill(ship.x+4,ship.y-2,muzzle,7)"
      " end"
      " "
      " --drawing shwaves"
      " for mysw in all(shwaves) do"
      "  circ(mysw.x,mysw.y,mysw.r,mysw.col)"
      "  mysw.r+=mysw.speed"
      "  if mysw.r>mysw.tr then"
      "   del(shwaves,mysw)"
      "  end"
      " end"
      " "
      " --drawing particles"
      " for myp in all(parts) do"
      "  local pc=7"
      ""
      "  if myp.blue then"
      "   pc=page_blue(myp.age)"
      "  else"
      "   pc=page_red(myp.age)"
      "  end"
      "  "
      "  if myp.spark then"
      "   pset(myp.x,myp.y,7)"
      "  else"
      "   circfill(myp.x,myp.y,myp.size,pc)"
      "  end"
      "  "
      "  myp.x+=myp.sx"
      "  myp.y+=myp.sy"
      "  "
      "  myp.sx=myp.sx*0.85"
      "  myp.sy=myp.sy*0.85"
      "  "
      "  myp.age+=1"
      "  "
      "  if myp.age>myp.maxage then"
      "   myp.size-=0.5"
      "   if myp.size<0 then"
      "    del(parts,myp)"
      "   end"
      "  end"
      " end"
      " "
      " --drawing ebuls"
      " for myebul in all(ebuls) do"
      "  drwmyspr(myebul)"
      " end"
      " "
      " --floats"
      " for myfl in all(floats) do"
      "  local mycol=7"
      "  if t%4<2 then"
      "   mycol=8"
      "  end"
      "  cprint(myfl.txt,myfl.x,myfl.y,mycol)"
      "  myfl.y-=0.5"
      "  myfl.age+=1"
      "  if myfl.age>60 then"
      "   del(floats,myfl)"
      "  end"
      " end"
      " "
      " print(\"score:\"..makescore(score),40,2,12)"
      " "
      " for i=1,4 do"
      "  if lives>=i then"
      "   spr(37,i*9-8,1)"
      "  else"
      "   spr(38,i*9-8,1)"
      "  end "
      " end"
      ""
      " spr(48,108,1)"
      " print(cher,118,2,14)"
      " "
      " --print(#buls,5,5,7)"
      "end"
      ""
      "function makescore(val)"
      " if val==0 then"
      "  return \"0\""
      " end"
      " return val..\"00\""
      "end"
      ""
      "function draw_start()"
      " cls(0)"
      " starfield()"
      " print(version,1,1,1)"
      ""
      " spr(21,peekerx,28+sin(time()/3.5)*4 )"
      " if sin(time()/3.5)>0.5 then"
      "  peekerx=30+rnd(60)"
      " end"
      "   "
      " spr(212,17,30,12,2)"
      " cprint(\"short shwave shmup\",64,45,6)"
      " "
      " if highscore>0 then"
      "  cprint(\"highscore:\",64,63,12)"
      "  cprint(makescore(highscore),64,69,12)"
      " end"
      ""
      " cprint(\"press any key to start\",64,90,blink())"
      " "
      " rectfill(0,115,128,128,1)"
      " cprint(\"learn how to make this game!\",64,116,12)"
      " cprint(\"bit.ly/shmupme\",64,122,12)"
      " "
      "end"
      ""
      "function draw_over()"
      " draw_game()"
      " cprint(\"game over\",64,40,8) "
      " "
      " cprint(\"score:\"..makescore(score),64,60,12)"
      " if score>highscore then"
      "  local c=7"
      "  if t%4<2 then"
      "   c=10"
      "  end"
      "  cprint(\"new highscore!\",64,66,c) "
      " end"
      " "
      " cprint(\"press any key to continue\",64,90,blink())"
      "end"
      ""
      "function draw_win()"
      " draw_game()"
      " cprint(\"congratulations\",64,40,12)"
      " cprint(\"score:\"..makescore(score),64,60,12)"
      ""
      " if score>highscore then"
      "  local c=7"
      "  if t%4<2 then"
      "   c=10"
      "  end"
      "  cprint(\"new highscore!\",64,66,c) "
      " end"
      ""
      " cprint(\"press any key to continue\",64,90,blink())"
      "end"
      ""
      "function draw_wavetext()"
      " draw_game()"
      " if wave==lastwave then"
      "  cprint(\"final wave!\",64,40,blink())"
      " else"
      "  cprint(\"wave \"..wave..\" of \"..lastwave,64,40,blink())"
      " end"
      "end"
      "-->8"
      "-- waves and enemies"
      ""
      "function spawnwave()"
      " if wave<lastwave then"
      "  sfx(28)"
      " else"
      "  music(10)"
      " end"
      " "
      " if wave==1 then"
      "  --space invaders"
      "  attacfreq=60"
      "  firefreq=20"
      "  placens({"
      "   {0,1,1,1,1,1,1,1,1,0},"
      "   {0,1,1,1,1,1,1,1,1,0},"
      "   {0,1,1,1,1,1,1,1,1,0},"
      "   {0,1,1,1,1,1,1,1,1,0}"
      "  })"
      " elseif wave==2 then"
      "  --red tutorial"
      "  attacfreq=60"
      "  firefreq=20"
      "  placens({"
      "   {1,1,2,2,1,1,2,2,1,1},"
      "   {1,1,2,2,1,1,2,2,1,1},"
      "   {1,1,2,2,2,2,2,2,1,1},"
      "   {1,1,2,2,2,2,2,2,1,1}"
      "  })"
      " elseif wave==3 then"
      "  --wall of red"
      "  attacfreq=50"
      "  firefreq=20"
      "  placens({"
      "   {1,1,2,2,1,1,2,2,1,1},"
      "   {1,1,2,2,2,2,2,2,1,1},"
      "   {2,2,2,2,2,2,2,2,2,2},"
      "   {2,2,2,2,2,2,2,2,2,2}"
      "  })"
      " elseif wave==4 then"
      "  --spin tutorial"
      "  attacfreq=50"
      "  firefreq=15"
      "  placens({"
      "   {3,3,0,1,1,1,1,0,3,3},"
      "   {3,3,0,1,1,1,1,0,3,3},"
      "   {3,3,0,1,1,1,1,0,3,3},"
      "   {3,3,0,1,1,1,1,0,3,3}"
      "  })"
      " elseif wave==5 then"
      "  --chess"
      "  attacfreq=50"
      "  firefreq=15"
      "  placens({"
      "   {3,1,3,1,2,2,1,3,1,3},"
      "   {1,3,1,2,1,1,2,1,3,1},"
      "   {3,1,3,1,2,2,1,3,1,3},"
      "   {1,3,1,2,1,1,2,1,3,1}"
      "  })"
      " elseif wave==6 then"
      "  --yellow tutorial"
      "  attacfreq=40"
      "  firefreq=10"
      "  placens({"
      "   {2,2,2,0,4,0,0,2,2,2},"
      "   {2,2,0,0,0,0,0,0,2,2},"
      "   {1,1,0,1,1,1,1,0,1,1},"
      "   {1,1,0,1,1,1,1,0,1,1}"
      "  })"
      "  "
      " elseif wave==7 then"
      "  --double yellow"
      "  attacfreq=40"
      "  firefreq=10"
      "  placens({"
      "   {3,3,0,1,1,1,1,0,3,3},"
      "   {4,0,0,2,2,2,2,0,4,0},"
      "   {0,0,0,2,1,1,2,0,0,0},"
      "   {1,1,0,1,1,1,1,0,1,1}"
      "  })"
      " elseif wave==8 then"
      "  --hell"
      "  attacfreq=30"
      "  firefreq=10"
      "  placens({"
      "   {0,0,1,1,1,1,1,1,0,0},"
      "   {3,3,1,1,1,1,1,1,3,3},"
      "   {3,3,2,2,2,2,2,2,3,3},"
      "   {3,3,2,2,2,2,2,2,3,3}"
      "  })"
      " elseif wave==9 then"
      "  --boss"
      "  attacfreq=60"
      "  firefreq=20"
      "  placens({"
      "   {0,0,0,0,5,0,0,0,0,0},"
      "   {0,0,0,0,0,0,0,0,0,0},"
      "   {0,0,0,0,0,0,0,0,0,0},"
      "   {0,0,0,0,0,0,0,0,0,0}"
      "  })"
      " end  "
      "end"
      ""
      "function placens(lvl)"
      ""
      " for y=1,4 do"
      "  local myline=lvl[y]"
      "  for x=1,10 do"
      "   if myline[x]!=0 then"
      "    spawnen(myline[x],x*12-6,4+y*12,x*3)"
      "   end"
      "  end"
      " end"
      " "
      "end"
      ""
      "function nextwave()"
      " wave+=1"
      " "
      " if wave>lastwave then"
      "  mode=\"win\""
      "  lockout=t+30"
      "  music(4)"
      " else"
      "  if wave==1 then"
      "   music(0)"
      "  else"
      "   music(3)  "
      "  end"
      "  "
      "  mode=\"wavetext\""
      "  wavetime=80"
      " end"
      ""
      "end"
      ""
      "function spawnen(entype,enx,eny,enwait)"
      " local myen=makespr()"
      " myen.x=enx*1.25-16"
      " myen.y=eny-66"
      " "
      " myen.posx=enx"
      " myen.posy=eny"
      " "
      " myen.type=entype"
      " "
      " myen.wait=enwait"
      ""
      " myen.anispd=0.4"
      " "
      " myen.mission=\"flyin\""
      " "
      " if entype==nil or entype==1 then"
      "  -- green alien"
      "  myen.spr=21"
      "  myen.hp=3"
      "  myen.ani={21,22,23,24}"
      "  myen.score=1"
      " elseif entype==2 then"
      "  -- red flame guy"
      "  myen.spr=148"
      "  myen.hp=2"
      "  myen.ani={148,149}"
      "  myen.score=2"
      " elseif entype==3 then"
      "  -- spinning ship"
      "  myen.spr=184"
      "  myen.hp=4"
      "  myen.ani={184,185,186,187}"
      "  myen.score=3"
      " elseif entype==4 then"
      "  -- yellow guy"
      "  myen.spr=208"
      "  myen.hp=20"
      "  myen.ani={208,210}"
      "  myen.sprw=2"
      "  myen.sprh=2"
      "  myen.colw=16"
      "  myen.colh=16"
      "  myen.score=5"
      " elseif entype==5 then"
      "  myen.hp=130"
      "  myen.spr=84"
      "  myen.ani={84,88,92,88}"
      "  myen.sprw=4"
      "  myen.sprh=3"
      "  myen.colw=32"
      "  myen.colh=24"
      "  "
      "  myen.x=48"
      "  myen.y=-24"
      "  myen.posx=48"
      "  myen.posy=25"
      "  "
      "  myen.boss=true"
      " end"
      "  "
      " add(enemies,myen)"
      "end"
      "-->8"
      "--behavior"
      ""
      "function doenemy(myen)"
      " if myen.wait>0 then"
      "  myen.wait-=1"
      "  return"
      " end"
      " "
      " --debug=myen.hp"
      " "
      " if myen.mission==\"flyin\" then"
      "  --flying in"
      "  --basic easing function"
      "  --x+=(targetx-x)/n"
      "  "
      "  local dx=(myen.posx-myen.x)/7"
      "  local dy=(myen.posy-myen.y)/7"
      "  "
      "  if myen.boss then"
      "   dy=min(dy,1)"
      "  end"
      "  myen.x+=dx"
      "  myen.y+=dy"
      "  "
      "  if abs(myen.y-myen.posy)<0.7 then"
      "   myen.y=myen.posy"
      "   myen.x=myen.posx"
      "   if myen.boss then"
      "    sfx(50)"
      "    myen.shake=20"
      "    myen.wait=28"
      "    myen.mission=\"boss1\""
      "    myen.phbegin=t"
      "   else"
      "    myen.mission=\"protec\""
      "   end"
      "  end"
      "  "
      " elseif myen.mission==\"protec\" then"
      "  -- staying put"
      " elseif myen.mission==\"boss1\" then"
      "  boss1(myen)"
      " elseif myen.mission==\"boss2\" then"
      "  boss2(myen)"
      " elseif myen.mission==\"boss3\" then"
      "  boss3(myen)"
      " elseif myen.mission==\"boss4\" then"
      "  boss4(myen)"
      " elseif myen.mission==\"boss5\" then"
      "  boss5(myen)"
      " elseif myen.mission==\"attac\" then  "
      "  -- attac"
      "  if myen.type==1 then"
      "   --green guy"
      "   myen.sy=1.7"
      "   myen.sx=sin(t/45)"
      "   "
      "   -- just tweaks"
      "   if myen.x<32 then"
      "    myen.sx+=1-(myen.x/32)"
      "   end"
      "   if myen.x>88 then"
      "    myen.sx-=(myen.x-88)/32"
      "   end"
      "  elseif myen.type==2 then"
      "   --red guy"
      "   myen.sy=2.5"
      "   myen.sx=sin(t/20)"
      "   "
      "   -- just tweaks"
      "   if myen.x<32 then"
      "    myen.sx+=1-(myen.x/32)"
      "   end"
      "   if myen.x>88 then"
      "    myen.sx-=(myen.x-88)/32"
      "   end   "
      "   "
      "  elseif myen.type==3 then"
      "   --spinny ship"
      "   if myen.sx==0 then"
      "    --flying down"
      "    myen.sy=2"
      "    if ship.y<=myen.y then"
      "     myen.sy=0"
      "     if ship.x<myen.x then"
      "      myen.sx=-2"
      "     else"
      "      myen.sx=2"
      "     end"
      "    end"
      "   end"
      "   "
      "  elseif myen.type==4 then"
      "   --yellow ship"
      "   myen.sy=0.35"
      "   if myen.y>110 then"
      "    myen.sy=1"
      "   else"
      "    "
      "    if t%25==0 then"
      "     firespread(myen,8,1.3,rnd())"
      "    end"
      "   end   "
      "  end"
      "  "
      "  move(myen)"
      " end"
      "  "
      "end"
      ""
      "function picktimer()"
      " if mode!=\"game\" then"
      "  return"
      " end"
      ""
      " if t>nextfire then"
      "  pickfire()"
      "  nextfire=t+firefreq+rnd(firefreq)"
      " end"
      " "
      " if t%attacfreq==0 then"
      "  pickattac()"
      " end"
      "end"
      ""
      "function pickattac()"
      " local maxnum=min(10,#enemies)"
      " local myindex=flr(rnd(maxnum))"
      " "
      " myindex=#enemies-myindex"
      " local myen=enemies[myindex]"
      " if myen==nil then return end"
      " "
      " if myen.mission==\"protec\" then"
      "  myen.mission=\"attac\""
      "  myen.anispd*=3"
      "  myen.wait=60"
      "  myen.shake=60"
      " end"
      "end"
      ""
      "function pickfire()"
      " local maxnum=min(10,#enemies)"
      " local myindex=flr(rnd(maxnum))"
      " "
      " for myen in all(enemies) do"
      "  if myen.type==4 and myen.mission==\"protec\" then"
      "   if rnd()<0.5 then"
      "    firespread(myen,12,1.3,rnd())"
      "    return"
      "   end"
      "  end"
      " end"
      " "
      " myindex=#enemies-myindex"
      " local myen=enemies[myindex]"
      " if myen==nil then return end"
      " "
      " if myen.mission==\"protec\" then"
      "  if myen.type==4 then"
      "   --yellow guy"
      "   firespread(myen,12,1.3,rnd())"
      "  elseif myen.type==2 then"
      "   --red guy"
      "   aimedfire(myen,2)"
      "  else"
      "   fire(myen,0,2)"
      "  end"
      " end"
      "end"
      ""
      ""
      "function move(obj)"
      " obj.x+=obj.sx"
      " obj.y+=obj.sy"
      "end"
      ""
      "function killen(myen)"
      " if myen.boss then"
      "  myen.mission=\"boss5\""
      "  myen.phbegin=t"
      "  myen.ghost=true"
      "  ebuls={}"
      "  music(-1)"
      "  sfx(51)"
      "  return"
      " end"
      ""
      " del(enemies,myen)   "
      " sfx(2)"
      " "
      ""
      " explode(myen.x+4,myen.y+4)"
      " local cherchance=0.1"
      " local scoremult=1"
      " "
      " if myen.mission==\"attac\" then"
      "  scoremult=2"
      "  if rnd()<0.5 then"
      "   pickattac()"
      "  end"
      "  cherchance=0.2"
      " end"
      " "
      " score+=myen.score*scoremult"
      " if scoremult!=1 then"
      "  popfloat(makescore(myen.score*scoremult),myen.x+4,myen.y+4)"
      " end"
      " "
      " if rnd()<cherchance then"
      "  dropickup(myen.x,myen.y)"
      " end"
      "end"
      ""
      "function dropickup(pix,piy)"
      " local mypick=makespr()"
      " mypick.x=pix"
      " mypick.y=piy"
      " mypick.sy=0.75"
      " mypick.spr=48"
      " add(pickups,mypick)"
      "end"
      ""
      "function plogic(mypick)"
      " cher+=1"
      " smol_shwave(mypick.x+4,mypick.y+4,14)"
      " if cher>=10 then"
      "  --get a life"
      "  if lives<4 then"
      "   lives+=1"
      "   sfx(31)"
      "   cher=0"
      "   popfloat(\"1up!\",mypick.x+4,mypick.y+4)"
      "  else"
      "   --points"
      "   score+=50"
      "   popfloat(makescore(50),mypick.x+4,mypick.y+4)"
      "   sfx(30)"
      "   cher=0"
      "  end"
      " else"
      "  sfx(30)"
      " end"
      "end"
      ""
      "function animate(myen)"
      " myen.aniframe+=myen.anispd"
      " if flr(myen.aniframe) > #myen.ani then"
      "  myen.aniframe=1"
      " end"
      " myen.spr=myen.ani[flr(myen.aniframe)]"
      "end"
      "-->8"
      "--bullets"
      ""
      "function fire(myen,ang,spd)"
      " local myebul=makespr()"
      " myebul.x=myen.x+3"
      " myebul.y=myen.y+6"
      " "
      " if myen.type==4 then"
      "  myebul.x=myen.x+7"
      "  myebul.y=myen.y+13"
      " elseif myen.boss then"
      "  myebul.x=myen.x+15"
      "  myebul.y=myen.y+23 "
      " end"
      " "
      " myebul.spr=32"
      " myebul.ani={32,33,34,33}"
      " myebul.anispd=0.5"
      " "
      " myebul.sx=sin(ang)*spd"
      " myebul.sy=cos(ang)*spd"
      " "
      " myebul.colw=2"
      " myebul.colh=2"
      " myebul.bulmode=true"
      " "
      " if myen.boss!=true then"
      "  myen.flash=4"
      "  sfx(29)"
      " else"
      "  sfx(34)"
      " end"
      " "
      " add(ebuls,myebul)"
      " "
      " return myebul"
      "end"
      ""
      "function firespread(myen,num,spd,base)"
      " if base==nil then"
      "  base=0"
      " end"
      " for i=1,num do"
      "  fire(myen,1/num*i+base,spd)"
      " end"
      "end"
      ""
      "function aimedfire(myen,spd)"
      " local myebul=fire(myen,0,spd)"
      " "
      " local ang=atan2((ship.y+4)-myebul.y,(ship.x+4)-myebul.x)"
      ""
      " myebul.sx=sin(ang)*spd"
      " myebul.sy=cos(ang)*spd "
      "end"
      ""
      "function cherbomb()"
      " local spc=0.25/(cher*2)"
      " "
      " for i=0,cher*2 do"
      "  local ang=0.375+spc*i"
      "  "
      "  local newbul=makespr()"
      "  newbul.x=ship.x"
      "  newbul.y=ship.y-3"
      "  newbul.spr=17"
      "  newbul.dmg=3"
      "  "
      "  newbul.sx=sin(ang)*4"
      "  newbul.sy=cos(ang)*4"
      " "
      "  add(buls,newbul)"
      " end"
      " "
      " big_shwave(ship.x+3,ship.y+3)"
      " shake=5"
      " muzzle=5"
      " invul=30"
      " flash=3"
      " sfx(33)"
      " "
      "end"
      "-->8"
      "--boss"
      ""
      "function boss1(myen)"
      " -- movement"
      " local spd=2"
      " "
      " if myen.sx==0 or myen.x>=93 then"
      "  myen.sx=-spd"
      " end"
      " if myen.x<=3 then"
      "  myen.sx=spd"
      " end"
      " -- shooting"
      " if t%30>3 then"
      "  if t%3==0 then"
      "   fire(myen,0,2)"
      "  end"
      " end"
      " "
      " -- transition"
      " if myen.phbegin+8*30<t then"
      "  myen.mission=\"boss2\""
      "  myen.phbegin=t"
      "  myen.subphase=1"
      " end"
      " move(myen)"
      "end"
      ""
      "function boss2(myen)"
      " local spd=1.5"
      " "
      " -- movement"
      " if myen.subphase==1 then"
      "  myen.sx=-spd"
      "  if myen.x<=4 then"
      "   myen.subphase=2"
      "  end"
      " elseif myen.subphase==2 then"
      "  myen.sx=0"
      "  myen.sy=spd"
      "  if myen.y>=100 then"
      "   myen.subphase=3"
      "  end "
      " elseif myen.subphase==3 then"
      "  myen.sx=spd"
      "  myen.sy=0"
      "  if myen.x>=91 then"
      "   myen.subphase=4"
      "  end  "
      " elseif myen.subphase==4 then"
      "  myen.sx=0"
      "  myen.sy=-spd"
      "  if myen.y<=25 then"
      "   -- transition"
      "   myen.mission=\"boss3\""
      "   myen.phbegin=t"
      "   myen.sy=0"
      "  end  "
      " end "
      " -- shooting"
      " if t%15==0 then"
      "  aimedfire(myen,spd)"
      " end"
      ""
      " move(myen)"
      "end"
      ""
      "function boss3(myen)"
      " -- movement"
      " local spd=0.5"
      " "
      " if myen.sx==0 or myen.x>=93 then"
      "  myen.sx=-spd"
      " end"
      " if myen.x<=3 then"
      "  myen.sx=spd"
      " end"
      ""
      " -- shooting"
      " if t%10==0 then"
      "  firespread(myen,8,2,time()/2)"
      " end "
      " "
      " -- transition"
      " if myen.phbegin+8*30<t then"
      "  myen.mission=\"boss4\""
      "  myen.subphase=1"
      "  myen.phbegin=t"
      " end"
      " move(myen)"
      "end"
      ""
      "function boss4(myen)"
      " local spd=1.5"
      " "
      " -- movement"
      " if myen.subphase==1 then"
      "  myen.sx=spd"
      "  if myen.x>=91 then"
      "   myen.subphase=2"
      "  end"
      " elseif myen.subphase==2 then"
      "  myen.sx=0"
      "  myen.sy=spd"
      "  if myen.y>=100 then"
      "   myen.subphase=3"
      "  end "
      " elseif myen.subphase==3 then"
      "  myen.sx=-spd"
      "  myen.sy=0"
      "  if myen.x<=4 then"
      "   myen.subphase=4"
      "  end  "
      " elseif myen.subphase==4 then"
      "  myen.sx=0"
      "  myen.sy=-spd"
      "  if myen.y<=25 then"
      "   -- transition"
      "   myen.mission=\"boss1\""
      "   myen.phbegin=t"
      "   myen.sy=0"
      "  end  "
      " end "
      ""
      " -- shooting"
      " if t%12==0 then"
      "  if myen.subphase==1 then"
      "   fire(myen,0,2)"
      "  elseif myen.subphase==2 then"
      "   fire(myen,0.25,2)"
      "  elseif myen.subphase==3 then"
      "   fire(myen,0.5,2)"
      "  elseif myen.subphase==4 then"
      "   fire(myen,0.75,2)"
      "  end"
      " end"
      " -- transition"
      " move(myen)"
      "end"
      ""
      "function boss5(myen)"
      " myen.shake=10"
      " myen.flash=10 "
      " "
      " if t%8==0 then"
      "  explode(myen.x+rnd(32),myen.y+rnd(24))"
      "  sfx(2)"
      "  shake=2"
      " end"
      ""
      " if myen.phbegin+3*30<t then"
      "\t if t%4==2 then"
      "\t  explode(myen.x+rnd(32),myen.y+rnd(24))"
      "\t  sfx(2)"
      "   shake=2"
      "\t end"
      " end"
      ""
      " if myen.phbegin+6*30<t then"
      "  flash=3"
      "  score+=100"
      "  popfloat(makescore(100),myen.x+16,myen.y+6)"
      "  bigexplode(myen.x+16,myen.y+12)"
      "  shake=15"
      "  enemies={}"
      "  sfx(35)"
      " end"
      "end")
    (p8-section gfx
      "00000000000220000002200000022000000000000000000000000000000000000000000000000000ccccccccccccccccc666cccc7777766c6cccccccccccccc0"
      "000000000028820000288200002882000000000000077000000770000007700000c77c0000077000ccccccccccccccccc777cccc7777776c776cccccccccccc0"
      "007007000028820000288200002882000000000000c77c000007700000c77c000cccccc000c77c00cccccccc77cccccc67776cccccc677ccc77cc777ccccccc0"
      "0007700000288e2002e88e2002e882000000000000cccc00000cc00000cccc0000cccc0000cccc00cccc6ccc77cccccc77777cccccc776ccc6777776cc6cccc0"
      "00077000027c88202e87c8e202887c2000000000000cc000000cc000000cc00000000000000cc000ccc67ccc77cccccc77c77ccccc677ccccc77776ccc76ccc0"
      "007007000211882028811882028811200000000000000000000cc000000000000000000000000000ccc77ccc77ccccc776c776cccc776cccccc776cccc77ccc0"
      "00000000025582200285582002285520000000000000000000000000000000000000000000000000ccc77ccc77ccccc7766777ccc677ccccccc77ccccc77ccc0"
      "00000000002992000029920000299200000000000000000000000000000000000000000000000000ccc77ccc77cccc67777777ccc776ccccccc77ccccc77ccc0"
      "09999000009999000000000000000000000000000330033003300330033003300330033000000000ccc77ccc77666c777666776c7777777cccc776cccc77ccc0"
      "9977990009aaaa9000000000000000000000000033b33b3333b33b3333b33b3333b33b3300000000ccc77ccc77777677cccc676c7777777cccc776cccc77ccc0"
      "9a77a9009aa77aa90000000000000000000000003bbbbbb33bbbbbb33bbbbbb33bbbbbb300000000ccc77ccc7666666cccccccccccccccccccc66ccccc77ccc0"
      "9a77a9009a7777a90000000000000000000000003b7717b33b7717b33b7717b33b7717b300000000ccc77ccccccccccccccccccccccccccccccccccccc77ccc0"
      "9a77a9009a7777a90000000000000000000000000b7117b00b7117b00b7117b00b7117b000000000ccc77cccccccccccc66677cc77cccc666cc666cccc77ccc0"
      "99aa99009aa77aa90000000000000000000000000037730000377300003773000037730000000000ccc77ccc777777ccc77777cc776ccc776c77777ccc77ccc0"
      "09aa900009aaaa900000000000000000000000000303303003033030030330300303303000000000ccc77ccc7777777cc676cccc677cc677cc77667ccc77ccc0"
      "00990000009999000000000000000000000000000300003030000003030000300330033000000000ccc676cc77ccc777c676ccccc77cc776c677cccccc77ccc0"
      "00ee000000ee00000077000000000000000000000880088008800880000000000000000000000000ccc676cc776cc677c67777ccc77cc77cc67776ccc676ccc0"
      "0e22e0000e88e00007cc700000000000000000008888888880088008000000000000000000000000ccc676cc776ccc77c67777ccc676676ccc67777cc676ccc0"
      "e2e82e00e87e8e007c77c70000000000000000008888888880000008000000000000000000000000ccc677cc676cc677c676cccccc7777cccccc677cc676ccc0"
      "e2882e00e8ee8e007c77c70000000000000000008888888880000008000000000000000000000000cccc77cc676c6776c677cccccc7777ccccccc77cc77cccc0"
      "0e22e0000e88e00007cc700000000000000000000888888008000080000000000000000000000000cccc77cc6777777cc677776ccc677cccc776777cc77cccc0"
      "00ee000000ee00000077000000000000000000000088880000800800000000000000000000000000cccc776cc77776ccc66666ccccc76cccc67777ccc77cccc0"
      "00000000000000000000000000000000000000000008800000088000000000000000000000000000ccccccccccccccccccccccccccccccccccccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccc666666666666666666666ccccccccccccc0"
      "000bbbb0000000000000000000000000000000000000000000000000000000000000000000000000666667777777777777777777777777777777777777766660"
      "000b0bb000000000000000000000000000000000000000000000000000000000000000000000000077777777777766677667766c6776cc776776777777777770"
      "00b00b00000000000000000000000000000000000000000000000000000000000000000000000000c777776c6776ccc77cc67ccccc7ccc76c67cc7cc7cc77760"
      "00b00880000000000000000000000000000000000000000000000000000000000000000000000000c77777ccc77cc7776ccc76c76c6cc67cc66cc76ccc6777c0"
      "08808788000000000000000000000000000000000000000000000000000000000000000000000000c67777c6c67c7777cc6c76c77c6ccc7cccccc77cc67776c0"
      "87880888000000000000000000000000000000000000000000000000000000000000000000000000cc7777cccc7cc667cccc66c6cc7cc66c7cc6c676c7777cc0"
      "88880880000000000000000000000000000000000000000000000000000000000000000000000000ccc77ccc6c67ccc6c676c6ccc77ccc6c7c67c67cc777ccc0"
      "08800000000000000000000000000000000000000000000000000000000000000000000000000000ccc67c67766776777777777777777777777767766776ccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000cccc777777777777777777777777777777777777777cccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccc77766666ccccccccccccccccccccc66666777ccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccccccccccccccccccccccccccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000cccccccccccccc7777ccccccccccc7777cccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccccc67776ccccccc67776ccccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccccccc677776cc67776ccccccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccccccccc677777776ccccccccccccccccccc0"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000ccccccccccccccccccccc67776ccccccccccccccccccccc0"
      "00000ee00000bbbbbbbb00000ee0000000000ee00000bbbbbbbb00000ee0000000000ee00000bbbbbbbb00000ee0000000000ee00000bbbbbbbb00000ee00000"
      "ee0008e7e1bbbbbaabbbbb1e7e8000eeee0008e7e1bbbbbaabbbbb1e7e8000eeee0008e7e1bbbbbaabbbbb1e7e8000eeee0008e7e1bbbbbaabbbbb1e7e8000ee"
      "e7e0138873bbbaa77aabbb3788310e7ee7e0138873bbbaa77aabbb3788310e7ee7e0138873bbbaa77aabbb3788310e7ee7e0138873bbbaa77aabbb3788310e7e"
      "8e783b333bbabaa77aababb333b387e88e783b333bbabaa77aababb333b387e88e783b333bbabaa77aababb333b387e88e783b333bbabaa77aababb333b387e8"
      "08e813bbbbbbbba77abbbbbbbb318e8008e813bbbbbbbbbaabbbbbbbbb318e8008e813bbbbbbbbbaabbbbbbbbb318e8008e813bbbbbbbbbaabbbbbbbbb318e80"
      "088811bbbbbbbbbaabbbbbbbbb11888008881133b33bbbbbbbbbb33b3311888008881133b33bbbbbbbbbb33b3311888008881133b33bbbbbbbbbb33b33118880"
      "0011133bbbbb33bbbb33bbbbb331110000113b11bbb3333333333bbb11b3110000113b11bbb3333333333bbb11b3110000113b11bbb3333333333bbb11b31100"
      "00bb113bbabbb33bb33bbbabb311bb0000bb13bb13bbb333333bbb31bb31bb0000bb13bb13bbb333333bbb31bb31bb0000bb13bb13bbb333333bbb31bb31bb00"
      "bb333113bbabbbbbbbbbbabb311333bbbb3331333333bba77abb3333331333bbbb3331333333bba77abb3333331333bbbb3331333333bba77abb3333331333bb"
      "bbbb31333bbaa7bbbb7aabb33313bbbbb7713ee6633333bbbb3333366ee3177bb7713ee6633333bbbb3333366ee3177bb7713ee6633333bbbb3333366ee3177b"
      "3b333313333bbb7777bbb333313333b337113eefff663333333366fffee3117337113eefff663333333366fffee3117337113eefff663333333366fffee31173"
      "c333333bb33333bbbb33333bb333333cc3773efff77f17711111f77fffe3773cc3773efff77f17711111f77fffe3773cc3773efff77f17711111f77fffe3773c"
      "0c3bb3b3bbb3333333333bbb3b3bb3c00c3b3eff777717711c717777ffe3b3c00c3b3eff777717711c717777ffe3b3c00c3b3eff777717711c717777ffe3b3c0"
      "00c1bb3b33bbbb3333bbbb33b3bb1c0000c1b3ef7777711cc7177777fe3b1c0000c1b3ef7777711cc7177777fe3b1c0000c1b3ef7777711cc7177777fe3b1c00"
      "00013bb3bb333bbbbbb333bb3bb3100000013b3eff777711117777ffe3b3100000013b3eff777711117777ffe3b3100000013b3eff777711117777ffe3b31000"
      "0331c3bb33aaa333333aaa33bb3c13300331c3b3eef7777777777fee3b3c13300031c3b3eef7777777777fee3b3c13000031c3b3eef7777777777fee3b3c1300"
      "3bb31c3bbb333a7777a333bbb3c13bb33bb31c3b33eee777777eee33b3c13bb303b31c3b33eee777777eee33b3c13b30003b1c3b33eee777777eee33b3c1b300"
      "3ccc13c3bbbbb333333bbbbb3c31ccc33ccc13c3bb333eeeeee333bb3c31ccc33bcc13c3bb333eeeeee333bb3c313cb303bc13c3bb333eeeeee333bb3c31cb30"
      "00003b3c33bbbba77abbbb33c3b3000000003b3c33bbb333333bbb33c3b300003c003b3c33bbb333333bbb33c3b300cc03c0333c33bbb333333bbb33c3330c30"
      "0003b3ccc333bbbbbbbb333ccc3b30000003b3ccc333bba77abb333ccc3b300000003b3cc333bba77abb333cc3b3000000003b3cc333bba77abb333cc3b30000"
      "00033c003bc33bbbbbb33cb300c3300000033c003bc33bbbbbb33cb300c33000000033c03bc33bbbbbb33cb30c33000000003bc03bc33bbbbbb33cb30cb30000"
      "0003c0003b3c3cb22bc3c3b3000c30000003c0003b3c3cb22bc3c3b3000c300000003c003b3c3cb22bc3c3b300c30000000003c0c3bc3cb22bc3cb3c0c300000"
      "0000000033c0cc2112cc0c33000000000000000033c0cc2112cc0c330000000000000000c330cc2112cc033c00000000000000000c30cc2112cc03c000000000"
      "00000000cc0000c33c0000cc0000000000000000cc0000c33c0000cc00000000000000000cc000c33c000cc0000000000000000000cc00c33c00cc0000000000"
      "00000000000000000000000000070000020000200200002002000020020000205555555555555555555555555555555502222220022222200222222002222220"
      "000bb000000bb0000007700000077000022ff220022ff220022ff220022ff2200578875005788750d562465d0578875022e66e2222e66e2222e66e2222e66e22"
      "0066660000666600606666066066660602ffff2002ffff2002ffff2002ffff2005624650d562465d05177150d562465d27761772277617722776177227716772"
      "0566665065666656b566665bb566665b0077d7000077d700007d77000077d700d517715d051771500566865005177150261aa172216aa162261aa612261aa162"
      "65637656b563765b056376500563765008577580085775800857758008577580056686500566865005d24d50056686502ee99ee22ee99ee22ee99ee22ee99ee2"
      "b063360b006336000063360000633600080550800805508008055080080550805d5245d505d24d500505505005d24d5022299222229999222229922222299222"
      "006336000063360000633600006336000c0000c007c007c007c00c7007c007c05005500505055050050000500505505020999902020000202099990202999920"
      "0006600000066000000660000006600000c7c7000007c0000077cc000007c000dd0000dd0dd00dd005dddd500dd00dd022000022022002202200002202200220"
      "00ff880000ff88000000000000000000200000020200002000000000000000003350053303500530000000000000000000000000000000000000000000000000"
      "0888888008888880000000000000000022000022220000220000000000000000330dd033030dd030005005000350053000000000000000000000000000000000"
      "06555560076665500000000000000000222222222222222200000000000000003b8dd8b3338dd833030dd030030dd03003e33e300e33e330033e333003e333e0"
      "6566665576555565000000000000000028222282282222820000000000000000032dd2300b2dd2b0038dd830338dd833e33e33e333e33e333e33e333e33e333e"
      "57655576555776550000000000000000288888822888888200000000000000003b3553b33b3553b3033dd3300b2dd2b033300333333003333330033333300333"
      "0655766005765550000000000000000028788782287887820000000000000000333dd333333dd33303b55b303b3553b3e3e3333bbe33333ebe3e333be3e3333b"
      "0057650000655700000000000000000028888882080000800000000000000000330550330305503003bddb30333dd3334bbbbeb44bbbebb44bbbbeb44bbbebe4"
      "00065000000570000000000000000000080000800000000000000000000000000000000000000000003553000305503004444440044444400444444004444440"
      "0066600000666000006660000068600000888000002222000022220000222200002222000cccccc00c0000c00000000000000000000000000000000000000000"
      "055556000555560005585600058886000882880002eeee2002eeee2002eeee2002eeee20c0c0c0ccc000000c0000000000000000000000000000000000000000"
      "55555560555855605588856058828860882228802ee77ee22ee77ee22eeeeee22ee77ee2c022220ccc2c2c0cc022220c00222200000000000000000000000000"
      "55555550558885505882885088222880822222802ee77ee22ee77ee22ee77ee22ee77ee2cc2cac0cc02aa20cc0cac2ccc02aa20c000000000000000000000000"
      "15555550155855501588855018828850882228802eeeeee22eeeeee22eeeeee22eeeeee2c02aa20cc0cac2ccc02aa20ccc2cac0c000000000000000000000000"
      "01555500015555000158550001888500088288002222222222222222222222222222222200222200c022220ccc2c2c0cc022220c000000000000000000000000"
      "0011100000111000001110000018100000888000202020200202020220202020020202020000000000000000c000000cc0c0c0cc000000000000000000000000"
      "00000000000000000000000000000000000000002000200002000200002000200002000200000000000000000c0000c00cccccc0000000000000000000000000"
      "000880000009900000089000000890000000000001111110011111100000000000d89d0000189100001891000019810000005500000050000005000000550000"
      "706666050766665000676600006656000000000001cccc1001cccc10000000000d5115d000d515000011110000515d0000055000000550000005500000055000"
      "1661c6610161661000666600001666000000000001cccc1001cccc1000000000d51aa15d0151a11000155100011a151005555550055555500555555005555550"
      "7066660507666650006766000066560000000000017cc710017cc71000000000d51aa15d0d51a15000d55d00051a15d022222222222222222222222222222222"
      "0076650000766500007665000076650000000000017cc710017cc710000000006d5005d6065005d0006dd6000d50056026060602260606022666666226060602"
      "000750000007500000075000000750000000000001111110011111100000000066d00d60006d0d600066660006d0d60020000002206060622222222020606062"
      "00075000000750000007500000075000000000001100001101100110000000000760067000660600000660000060660020606062222222200000000022222220"
      "00060000000600000006000000060000000000001100001101100110000000000070070000070700000770000070700022222220000000000000000000000000"
      "0007033000700000007d330003330333000000000022220000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000d3300000d33000028833003bb3bb3000000000888882000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0778827000288330071ffd1000884200002882000888882000288200000000000000000000000000000000000000000000000000000000000000000000000000"
      "071ffd10077ffd700778827008ee8e800333e33308ee8e80088ee883000000000000000000000000000000000000000000000000000000000000000000000000"
      "00288200071882100028820008ee8e8003bb4bb308ee8e8008eeee83000000000000000000000000000000000000000000000000000000000000000000000000"
      "07d882d00028820007d882d00888882008eeee800088420008eeee80000000000000000000000000000000000000000000000000000000000000000000000000"
      "0028820007d882d000dffd0008888820088ee88003bb3bb3088ee880000000000000000000000000000000000000000000000000000000000000000000000000"
      "00dffd0000dffd000000000000222200002882000333033300288200000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000077777777777777777777777777777777777777777777777777777777777777777777777777777777777777700000"
      "00000000000000000000000000000000007777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777000"
      "0000149aa94100000000012222100000077778888778877778878888887888887777888887788777788777778888877777788887777887777788788888777700"
      "00019777aa921000000029aaaa920000077888888878877778878888887888888777888888778877887777778888887778888888877888777888788888877700"
      "0d09a77a949920d00d0497777aa920d077788e778878877778878877777887788877887788878877887777778877887778877888877888777888788778877770"
      "0619aaa9422441600619a779442941607788e7777778877778878877777887778877887778877888877777778877887788777888887888878888788778877770"
      "07149a922249417006149a9442244160778877777778888888878888887887788877887788877888877777778888877788778888887888878888788888777770"
      "07d249aaa9942d7006d249aa99442d60778877777778888888878888887888888777888888777788777777778888887788888888887887888788788888877770"
      "067d22444422d760077d22244222d7707788e7777778877778878877777888887777888887777788777777778877e8878888888888788788878878877e887770"
      "0d666224422666d00d776249942677d077788e778878877778878877777887888777887888777788777777778877788778888888877887787788788777887770"
      "066d51499415d66001d1529749251d10077888888878877778878888887887788877887788877788777777778888888778888888877887787788788888887700"
      "0041519749151400066151944a1516600777788887788777788788888878877788878877788877887777777788888e7777788887777887777788788888e77700"
      "00a001944a100a0000400149a4100400007777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777000"
      "00000049a400090000a0000000000a00000077777777777777777777777777777777777777777777777777777777777777777777777777777777777777700000"
      "00000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section label
      "0000000000000000000000000000000000000000000000000000000d000000000000000000000000000000000000000000000000000000000000000000000100"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000021200000000000000100000000022102000020000000002200000022212000000000000220000000000000000000000000000000000"
      "00000000000000000000000020000000000000220000000022200000020000000002220000022220000000000000200000200000000000000000d00000000000"
      "00000000000000000000000000000060000000220000000012200200000000000002022000021200000000200022000000000000000000000000000000000000"
      "00000000000000000000000000000000000000020000000022202200002000000022220000000000000000002220000000000000000000000000000000000000"
      "00000000000000000000000000000000002000020000000022200000022000000222220000000200000000002222000000000000200000000000000000000000"
      "00000000000000000000000000000000000000020000000002220000220000000222220000005000000002022220000000000002000000000000000000000000"
      "00000000000000000000000000000000000000020000000012001022200200000222220000002000000020d22200000000000002000000000000000000000000"
      "00000000000000000000000000000000000000002000000022202222200220022222200000000000000220222000020000000220000002000000000000000000"
      "00000000000000000000000000000000000000002000000002202222200222222222200000000000000200222000000000002200000022000000000000000000"
      "00000000000000000600000000000000000000002200000002222222200222222222200000220000000202200000000002022000002222000000000000000000"
      "00000000000000000006000000000000000000000200000002222222222222222222000002200000002000000000000020222000222222000000000000000000"
      "00000000000000000000000000000000000000000000000000222222222222222220000202200000002000000020000222222222222222000000000000000000"
      "00000000006000000000000000000000002000000000000000222222222222222200000022000020022020000200002222222222222222000000000000000000"
      "00000000000000000000002000002000000000000000002000000222222222222022002222000020220000002000022222222222222220000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000077777777777777777777777777777777777777777777777777777777777777777777777777777777777777700000000000000000000"
      "00000000000000000007777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777000000000000000000"
      "00000000000000000077778888778877778878888887888887777888887788777788777778888877777788887777887777788788888777700000000000000000"
      "00000000000000000077888888878877778878888887888888777888888778877887777778888887778888888877888777888788888877700000000000000000"
      "0000000000000000077788e7788788777788788777778877888778877888788778877777788778877788778888778887778887887788777700000d0000000000"
      "000000000000000007788e77777788777788788777778877788778877788778888777777788778877887778888878888788887887788777700000000d0000000"
      "00000000000000000778877777778888888878888887887788877887788877888877777778888877788778888887888878888788888777770000000000000000"
      "00000000000000000778877777778888888878888887888888777888888777788777777778888887788888888887887888788788888877770000000000000000"
      "000000000000200007788e7777778877778878877777888887777888887777788777777778877e8878888888888788788878878877e887770000020000000000"
      "0000000000000000077788e778878877778878877777887888777887888777788777777778877788778888888877887787788788777887770000020000000000"
      "00000000000002000077888888878877778878888887887788877887788877788777777778888888778888888877887787788788888887700000220000000000"
      "000000000000020000777788887788777788788888878877788878877788877887777777788888e7777788887777887777788788888e77700002220000000000"
      "00000000000000000007777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777000022522000000000"
      "00000000000010100000077777777777777777777777777777777777777777777777777777777777777777777777777777777777777700000012121200000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000222222200010000"
      "00000000000000000100000000000660606006606660666000000660606060606660606066600000066060606660606066600000000000002212121200000000"
      "00000000000000000200000000006000606060606060060000006000606060606060606060000000600060606660606060600000000000022222222200000000"
      "00000000000000000000000000006660666060606600060000006660666060606660606066000000666066606060606066600010000000121212121200000000"
      "00000000000000000000000000000060606060606060060000000060606066606060666060000000006060606060606060000022000221222122212200000000"
      "00000000000000000000000000006600606066006060060000006600606066606060060066600000660060606060066060000012001212121212120000000000"
      "00030300000303000002000000000000000000000000000000000000000000000000000000000000000000000000000000000022222222200222200000000006"
      "003bbb00003bbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012021212000212100000000000"
      "03071b0000071b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020212221000122000000000000"
      "bb00333b330033000000020200000000000000000000000000000000000000000000000000000000000000000000000000000002021212101210000000000000"
      "1b0000371b0000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000001022122212220000000000000"
      "33000003700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000101212121212000000000000"
      "0010000003000120002100000000b000b000b0000000000000000000000000000000000000000000000000000000000000000000212121212121000060033003"
      "0000000000b002b000b0100000b000b000b000b000000000001100000000000000000000000000000011000000000000000000000212121210000000d033b33b"
      "00000000b000b000b020b000000000000000000000011100000001000000000000000000000000101000000000000000000000000121212100000020003bbbbb"
      "000000000000000000000000000000000000000000000000000000001111000000000000001110000000001000000000000000600032321000303002003b7717"
      "0000000000210020012000000000111111111111110000010000000000001111111111111100000000010100001111111111100003bbb12103bbb001000b7117"
      "000000120332133012120000000111111111111111100001011111000000000000000000000000100100000001111111111111303071b2121271b01200003773"
      "0000012133b33b3321202120000111111111111111111000000000111111000000000000001111000000000111111111111113bbb00333b33003302100030330"
      "000000123bbbbbb3111211100001111222225511111111100000000000001111111111111100000000001111111552e222111171b0021371b100001200030000"
      "000000013b7717b321212000000111222222255551111111100000000000000000000000000000001111111111556eee77211103300120372100012000000000"
      "000000001b7117b112101000000111272722666655511111111111110000000000000000000000111111111555666ee22e21110000001001300112100b000b00"
      "033003302137732121212000000111222eee666666555511111111111111111111111111111111111555555566666222ee211100000120000021000b000b000b"
      "33b33bb313b33131111110000001112222effffff6666555555111111111111111111111111115555556666666ffff22ee211100000011010100000000000000"
      "bbbbbbb3b321b131212120000001112e22ffffffffff6665555555111111111111111111115555566666fffffffffffeee211100000020212100000000000000"
      "3b7717b3121112111211130300011323efffffffffffff6666655555555555555555555555555666666ffffffffffffeeee111000000b211b000b00000000000"
      "0b7117b12121212121213bbb00013bbbeffffffff77ffffff6661117777711111111111111111666ffff777f7f7fffffeee1110000b001b120b000b000000000"
      "00377311111111110303071b0001171befffffffff777f7fffff1117777711111111ccc1111116fffff777777777ffffeee11100000001111000000000000000"
      "03033031212001203bbb00333b331133efffffff777777777fff11177777711111111ccc11111ffff77777777777ffffeee11100000000212001200000000000"
      "0300013111100010071b0000371b11eeeffffff777777777f7771117777771111111cccc77117777777777777777ffffeee11100000001111131300000303000"
      "0001212121210021203300000370111eeefffff777777777777771117777111111111cc77711777777777777777fffffeee111000000212123bbb00003bbb000"
      "0011111111110111101000000003111eeefff3fff37773777777711177771111111ccc777111777777777777777ffffeeee11100000011313071b0000071b000"
      "00211121012001001120000000001111eee3fff3777377737777771111111c1c1cccc77711117777777777777f7fffeeee111020000003bbb00333b330033000"
      "00111111011100111110000000000111eeeffffff7777777777777111111cccccccc777111177777777777f777ffffeeee11100000000171b0000371b0000000"
      "0000210000012b110b000b00000000111eeefffffffff777777777711111cccccccc771111777777777f777ff7fffeeee1110001000001133100003700000000"
      "00000000000b111b010b000b0100000111eeeeffffff77777777777711111ccccc111111777777777fff7777ffffeeee11303000003031111100000030000000"
      "00000000000011210000000000000000111eeeeffffff777777777777111111111111177777777777777f77fffeeeee113bbb00003bbb0211000000000000000"
      "000000001000111100000000000000000111eeeeffffff7f7777777777771111111777777777777777777ffffeeeee313171b0000071b1110000000000000000"
      "000000000110211000000000000000000011eeeeeeffff9777777777777777777777777777777777777ffffeeeeee3bbb00333b330033111000000000b000b00"
      "000b000b000001100000110000000000000111e9eeeaff9ff777777777777777777777777777777737ff3fee3ee11171b0000371b00001100000000b000b000b"
      "0b000b000b00010000011a000000000000001aaeeeeeeeffff777777777777777777777777777737ff3fee3eee31111330000037000011110000000000000000"
      "000000000000000000100a00a000a000a00099991eeeeeeeeff7777777777777777777777777777ffeeeeeee1111110000000000300111110010000000000000"
      "000000000000000006009100000a0000aa99aaa99a1eee77eeaff777777777777777777777777fffee77ee111111100000000000000111100110000000000000"
      "00000100000001100000099990000a009aaa7777aa191eaeeeeeff777777777777777777777ffeeee7eee1111110000000000000103311331100000000330033"
      "00000130300100313a099aaaa99000069a77777777a99aeeeeeeeeee77777777777777777eeeeeeeeee1111111000b000b000b00033b33b331000000033b33b3"
      "000003bbb00103bbba09a7777a900a099aaaa777777aaa991eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1111111000b000b000b000b03bbbbbb3000000003bbbbbb"
      "00303071b0010071b19a777777a9009aa7777aa77777a7aa99a1eeee7ee77e77777e77ee7eeeeee111111100000000000000000003b7717b3000000003b7717b"
      "03bbb00333b33013319a777777a909a77777777a7777a777aa91111eeeeaeeeeeeeeeeeeea11111111111000000000000033003301b7117b0000000000b7117b"
      "0071b0000371b010019a777777a99a7777777777a7777a777a991a11a777711a1111111a111111111100000000000000033b33b3300377300033003300037730"
      "0003300100370000009a777777a99a7777777777a7777a7779911a1aa9a97a1111111a1a9aa9a111770000000000000003bbbbbb30303303033b33b330303303"
      "0000000000003000a119a7777a99a777777777777a777a9777aa09a7777aa91a111119a777a7a907770000000000000003b7717b3130000303bbbbbb30300003"
      "000000000000100011119aaaa999a777771777777a777a9aa99909a7a777a7aa9aa977777a7779a0700000000000000000b7117b0001111103b7717b30000000"
      "000000010000009011111999aaaaa777772177777a77a7a777a9a77777a77777a77a977777777a947700000000000000000377300001001000b7117b00000000"
      "000000000000000011a1119a7777a777777227777a7a77a777a97777777777779777a7777a777957772240000000000000303303000001010103773000000000"
      "0000000100010011a111a9a777777a7777772177aaa77797779a77777777777aa99a7a7777f99e07999922000000000000300003100011100130336300000000"
      "0000000000001111111119a777777a7777777217a77777779a77777777a7777997177aaaa7ff490a9a4400020000000000000000010000000030000300000000"
      "0000000000011111111119a777777aa7777772201777777aa777a777777a77a7229aa77a7ffffaa4424200020000006000010000000000000110000000000000"
      "00000000000011111011199777777a9aa7777a210a7777aa11111aaaa9779772277777777fffaf44222020000000000000010000000000011000000000000000"
      "0000000000011111000a119a7777a9199aaaa992011aaa1117c1c117a777402277777777ffffffa9240000000000000100000000000000110000000000000000"
      "000000000000101100001119aaaa9119099990000015111c11111111770022f7f7777777ffffff99402200000000000000100000000000010110000001000000"
      "0000000000000011aaa1111aa99900110000a221005111111010100110002fff7777777fffffff44000200000000000001000000000000000000000000000000"
      "000000000000000000001a111000000aa000788211121111211221211005f4ff7f7777ffffffe444400000000000000010000000000000000000000000000000"
      "00000000000000000000000011a000000007128821122100cc0110211005f267f7ff7ff7fffffa94400000600000000100000000000000000000000000000000"
      "000000000000000000000001010011000a7702882122000c77c01012215514fffa7fff7ffffff999400000000200000000000001000000000000000000000000"
      "0000000000000000000000000000000aa7a00288822011c7777c10212102244ffe7afffe7fffff44440000000000000000600000000000000000100000000000"
      "000000000000000000000010000000a77a110288222015c7777c51022228849ffea7aff4fff4fffe622060000000000000000000000000000001000000000000"
      "00000000000000000000000110000a777a1100228110110c77c515021288899f44e77af4fff24e44424400000000010000000000000000000000111000000000"
      "0000000000000000011000061000a777a101128881101500cc05151022884a9f24fa7ae24fe20e90442260000000100000000000000000000000000100000000"
      "000000000000000001000000000a777a0000228810cc01d00011c15104224494050a77a24ef40540044200000000000000000000000000000000001000000000"
      "0000000000000000000000000aa777a0100028820c77c001010ccc01508202420f00a77a44e20022002200000000100000000000000000010001000000000000"
      "000000000000000000000010a7777a0110112882c7777c0001c777c0108222000440a77a40402001000010000101100000000000000000000010000000000000"
      "0000000000024442eeeeeeeee777a10110012811c7777c011cc777cc1082222001002a77a0402001000000001000000000000000000100001000000000000000"
      "0000000000000002228888888eeeeeeeeeeeee251c77c0d0d1c777c01082020000002a77a2442000110000011010110010000000000110000100000000000000"
      "00000000d000000000222228888888888888ee2160cc0150d10ccc0110826000000020a77a411200000000010000000000000000100100000010000000000000"
      "0000000000000000001001122288888888888e20d1000100d500c00110222200000221a777a10000111001011110100100000000010101100001000000000000"
      "0000000000000001001002211222122222222851111100000d100550022022211111110a777a0111100000111111001000000100000100110000000000000000"
      "00000000000000000000012221111111112222515100000000d111001222211111111010a777a111110000110111111000000000001000000000100000000000"
      "000000000000110000000001111111111111121111100000000110001222222eeeee0000a777a211111000010000100001000100000100001000110000000000"
      "00000000000011000000000111111111c11111111011111111111111022221888888888eeeeea110111111111000011000011000000110001100010000000000"
      "00000000000000000000000111111111111111111000001111111111000012228888888888888eeee10000111000110000011100000110001100000000000000"
      "0000000000000000000000000000111111111100111000000000010000111112221122222288888888420000000111010001010d000010000000000000000000"
      "00000000000000000000000000011111111110000110000000000000111100010010011021121122222200000011000000010000000000000000000000000000"
      "00000000000000000000000000001111111100000000100000000000010100111111000012212101101000000000001000001010000000100000000000000000"
      "00000000000000010000000000111111111110000000000110000000000111111111111111221111000111000000001000001111000000000000000000000000"
      "00000000000000000000000011111111111101001000000000010000011111111111111111111001000010000000000000000110010000000000000000000000"
      "00000000000000000000000010110111100000000000000000000000010011111111111111111110011000100000000000000000000000000000000000000000"
      "00000000000000000000000001001101100000000000000000000001001111011111111111111100000010000000000000000000000000000100000010000000"
      "00000000000000000000000101001010010000000000000100000000001100111111111111111000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000001000000000000000000000111111111111000000011000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000001000000000000000000000011111111110001000000000000000000000000000000000000000000000000000"
      "000000000000000000000d0000000000000000000000000000000000001000011101111111110000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000001001111000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000001000100001000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000001110000001000000000000000000000010000000000000000000000000000"
      "00000000000000000000000001000001000000000000000000000000000000000011100101000100d00000000600000000000000000000000000000000000000"
      "")
    (p8-section sfx
      "000100003452032520305202e5202b520285202552022520205201b52018520165201352011520010200f5200c5200a5200852006520055200452003510015200052000000000000000000000000000100000000"
      "000100002b650366402d65025650206301d6201762015620116200f6100d6100a6100761005610046100361002610026000160000600006000060000600006000000000000000000000000000000000000000000"
      "00010000377500865032550206300d620085200862007620056100465004610026000260001600006200070000700006300060001600016200160001600016200070000700007000070000700007000070000700"
      "000100000961025620006000060000600006000060000600006000060000600006000060000600006000060000600006000060000600006000060000600006000060000600006000060000600006000060000600"
      "00060000010501605019050160501905001050160501905016050190601b0611b0611b061290001d000170002600001050160501905016050190500105016050190501b0611b0611b0501b0501b0401b0301b025"
      "00060000205401d540205401d540205401d540205401d54022540225502255022550225500000000000000000000025534225302553022530255301d530255302253019531275322753027530275322753027530"
      "000600001972020720227201b730207301973020740227401b74020740227402274022740000000000000000000001672020720257201b730257301973025740227401b740277402274027740277402774027740"
      "011000001f5501f5501b5501d5501d550205501f5501f5501b5501a5501b5501d5501f5501f5501b5501d5501d550205501f5501b5501a5501b5501d5501f5502755027550255502355023550225502055020550"
      "011000000f5500f5500a5500f5501b530165501b5501b550165500f5500f5500a5500f5500f5500a550055500a5500e5500f5500f550165501b5501b550165501755017550125500f5500f550125501055010550"
      "011000001e5501c5501c550175501e5501b550205501d550225501e55023550205501c55026550265500000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0110000017550145501455010550175500b550195500d5501b5500f5501c550105500455016550165500000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "090d00001b0001b0001b0001d0001b0301b0001b0201d0201e0302003020040200401e0002000020000200001b7001d7001b7001b7001b7001d700227001a7001b7001b700167001b7001b7001b7001c7001c700"
      "050d00001f5001f0001f500215001f5301f0001f52021520225302453024530245302250024500245002450000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010d00002200022000220002400022030220002203024030250302703027030270302500027000270002700000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "4d1000002b0202b0202b0202b0202b0202b0202b0202b0202b020290202b0202c0202b0202b0202b0202602026020260202702027020270202b0202b0202b0202a0302a0302a0302703027030270302003020030"
      "4d1000002003028030280302c0302a0302a0302a0302703027030270302c0302a030290302e0302e0300000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010f00001e050000001e0501d0501b0501a0601a0621a062000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "050f00001b540070001b5401a54018540175501755217562075000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000"
      "010c0000290502c0002a00029055290552a000270502900024000290002705024000240002400027050240002a05024000240002a0552a055240002905024000240002400029050240002a000290002405026200"
      "510c00001431519315203251432519315203151432519325203151431519325203251431519315203251432519315203151432519325203151431519325203251431519315203251432519315203151432518325"
      "010c00000175001750017500175001750017500175001750017500175001750017500175001750017500175001750017500175001750017500175001750017500175001750017500175001750017500175001750"
      "010c0000195502c5002a50019555195552a500185502950024500295001855024500245002450018550245001b55024500245001b5551b555245001955024500245002450019550245002a500295001855026500"
      "010c0000290502c0002a00029055290552a000270502900024000290002000024000240352504527050240002a050240002f0052d0552c0552400029050240002400024000240002400024030250422905026200"
      "010c0000195502c5002a50019555195552a500185502950024500295002050024500145351654518550245001b550245002f5051e5551d5552450019550245002450024500245002450014530165401955026500"
      "010c00002c05024000240002a05529055240002e050240002400029000270502400024000240002e050240003005024000240002e0552d05524000300502400024000290002905024000270002a0002900028000"
      "510c0000143151931520325143251931520315163251932516315183151932516325183151931516325183251b3151e315183251b3251e315183151b3251e325183151b3151d325183251b3151d315183251b325"
      "010c00000175001750017500175001750017500175001750037500375003750037500375003750037500375006750067500675006750067500675006750067500575005750057500575005750057500575005750"
      "010c00001d55024500245001b55519555245001e550245002450029500165502450024500245001e550245001e55024500245001d5551b555245001d5502450024500295001855024500275002a5002950028500"
      "11050000385623555233552315522f5522d5522b5522954227552265522355222552215521e5421d5421a5421854217542155421454212542105420e5420d5320b53209522075120551203512015120051200512"
      "48020000173520f302113420932208322073200735000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400"
      "080c000013056170661c06620066220362905631036320063600632006270061f0061900617000120002a00027000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000a0000070560c0660f07616076180661f056220472703733037330573c0673e0062b00625006200061b0061700614006110060f0060d0060c0060a006090060600606006050060500600000000000000000000"
      "000400000744007420074200a40000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400004000040000400"
      "4a0200002c6412f66130661316613766132661326612b6612866125671226611e661146611a651166510864111641056410c64105641046410264102631026310163101621006210062100611006110061100611"
      "010100000914008150081600f160121400f1400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "020400003b6702b6403b67021620376702867031670266502c6502a650276502565022650206501d6501b6501965017640166401464012640106400d6400c6300a63008620076200562004620026200162000620"
      "010a00000c4200c4200c4200c4200c4200c4200c4200c4200f4200f4200f4200f4200f4200f4200f4200f42010420104201042010420104201042010420104201442014420144201442014420144201442014420"
      "010a00000532105320053200532005320053200532005320083200832008320083200832008320083200832009320093200932009320093200932009320093200d3200d3200d3200d3200d3200d3200d3200d320"
      "000a002034615296152b6161e6061c6401d6452b6152760528615296152b6151e6001c6401d6452b6152761534615296152b6161e6061c6401d6452b6152760528615356152b6151e6051c6401d6452b61527615"
      "050a00200232002320023200232002320023200232002320023200230502325023250232002325023200232503320033200332003320033200332003320033200732007320073200732007320073200732007320"
      "010a000002320023200232002320023200232002320023200a3200a3200a3200a3200a3200a3200a3200a32005320053200532005320053200532005320053200332003320033200332003320033200332003320"
      "010a000009220092200922009220092200922009220092200e2200e2200e2200e2200e2200e2200e2200e2200a2200a2200a2200a2200a2200a2200a2200a2200022000220002200022001220012200122001220"
      "010a000005220052200522005220052200522005220052200e2200e2200e2200e2200e2200e2200e2200e2200a2200a2200a2200a2200a2200a2200a2200a2200022000220002200022001220012200122001220"
      "010a00000d2200d2200d2200d2200d2200d2200d2200d220052200522005220052200522005220052200522011220112201122011220112201122011220112200322003220032200322003220032200322003220"
      "150a00001522015220152201522015220152201522015220152201522015220152201322013220152201522016220162201622016220162201622016220162201922019220192201922019220192201922019220"
      "150a00001a2201a2201a2201a2201a2201a2201a2251a2251d2201d2201d2201d2201d2201d2201d2201d22019220192201922019220192201922019220192201622016220162201622016220162201622016220"
      "150a0000192201922019220192201922019220192251922511220112201122011220112201122011220112201d2201d2201d2201d2201d2201d2201d2201d22018220192211a2211d22121221252212622126221"
      "090a00001d2171a217212172221729217262172d2172e2171d2171a2172121722217112170e21715217162171d2171a217212172221729217262172d2172e2171d2171a2172121722217112170e2171521716217"
      "090a000029217262172d2172e2173521732217392173a21729217262172d2172e2171d2171a2172121722217112170e21715217162171d2171a2172121722217112170e21715217162170521702217092170a217"
      "010a00000e003296000e0031e600286151d6052b605276150e003296052b6151e600286151d6452b615276051f6501f6301f6201e6001f6251f6251f625276050e003356052b6051e605106111c6112862133631"
      "5c030000131212513131151381711b1613b1513b1413c14116141291413913135131321312d13228132221321c13216132131321d1320e1320d1320a132091320813206122051220412203122031220312201120"
      "5c0400000817120161181610f17108171171711017109171071710d1610f161091510715106151051410514105132041320313202132021320113201132001320113201132011320112200122001220012200122")
    (p8-section music
      "04 04050644"
      "00 07084749"
      "04 090a484a"
      "04 0b0c0d44"
      "00 0e084344"
      "04 0f0a4344"
      "04 10114e44"
      "01 12131415"
      "00 16131417"
      "02 18191a1b"
      "00 24256844"
      "01 26272844"
      "00 26282966"
      "00 26272a65"
      "00 262a2b65"
      "00 26272c44"
      "00 26292d44"
      "00 26272c44"
      "00 262a2e44"
      "00 28292f44"
      "00 28293044"
      "00 272b2f44"
      "02 25243144"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a2d2d2063686572727920626f6d620a2d2d206279206c617a7920646576730a0a66756e6374696f6e205f696e697428290a202d2d746869732077696c6c20636c656172207468652073637265656e0a20636c732830290a200a2063617274646174612822636865727279626f6d6222290a206869676873636f72653d646765742830290a200a2076657273696f6e3d227631220a200a20737461727473637265656e28290a20626c696e6b743d310a20743d300a206c6f636b6f75743d300a200a2073")
    (hex 256 "68616b653d300a20666c6173683d300a0a2064656275673d22220a200a207065656b6572783d36340a200a202d2d206c6f676f20616e69202d2d0a09666164657461626c653d7b7b302c302c302c302c302c302c302c302c302c302c302c302c302c302c307d2c7b312c312c3132392c3132392c3132392c3132392c3132392c3132392c3132392c3132392c302c302c302c302c307d2c7b322c322c322c3133302c3133302c3133302c3133302c3133302c3132382c3132382c3132382c3132382c3132382c302c307d2c7b332c332c332c3133312c3133312c3133312c3133312c3132392c3132392c3132392c3132392c3132392c302c302c307d2c7b342c")
    (hex 512 "342c3133322c3133322c3133322c3133322c3133322c3133322c3133302c3132382c3132382c3132382c3132382c302c307d2c7b352c352c3133332c3133332c3133332c3133332c3133302c3133302c3132382c3132382c3132382c3132382c3132382c302c307d2c7b362c362c3133342c31332c31332c31332c3134312c352c352c352c3133332c3133302c3132382c3132382c307d2c7b372c362c362c362c3133342c3133342c3133342c3133342c352c352c352c3133332c3133302c3132382c307d2c7b382c382c3133362c3133362c3133362c3133362c3133322c3133322c3133322c3133302c3132382c3132382c3132382c3132382c307d2c7b39")
    (hex 768 "2c392c392c342c342c342c342c3133322c3133322c3133322c3132382c3132382c3132382c3132382c307d2c7b31302c31302c3133382c3133382c3133382c342c342c342c3133322c3133322c3133332c3132382c3132382c3132382c307d2c7b31312c3133392c3133392c3133392c3133392c332c332c332c332c3132392c3132392c3132392c302c302c307d2c7b31322c31322c31322c3134302c3134302c3134302c3134302c3133312c3133312c3133312c312c3132392c3132392c3132392c307d2c7b31332c31332c3134312c3134312c352c352c352c3133332c3133332c3133302c3132392c3132392c3132382c3132382c307d2c7b31342c3134")
    (hex 1024 "2c31342c3133342c3133342c3134312c3134312c322c322c3133332c3133302c3133302c3132382c3132382c307d2c7b31352c3134332c3134332c3133342c3133342c3133342c3133342c352c352c352c3133332c3133332c3132382c3132382c307d7d0a0a20636c73283132290a207370722831302c34302c33342c362c35290a20637072696e74282261206c617a7920646576732067616d65222c2036342c38302c37290a20637072696e7428226279206b7279737469616e206d616a6577736b69222c2036342c38362c37290a200a2066616465706572633d310a200a207265706561740a2020646f6661646528290a202066616465706572632d3d30")
    (hex 1280 "2e30370a2020666c697028290a20756e74696c282066616465706572633c3d3020290a200a2066616465706572633d300a20646f6661646528290a20666f7220693d302c333020646f0a2020666c697028290a20656e640a200a207265706561740a2020646f6661646528290a202066616465706572632b3d302e30370a2020666c697028290a20756e74696c282066616465706572633e3d3120290a2066616465706572633d300a20636c7328290a20646f6661646528290a20666f7220693d302c313020646f0a2020666c697028290a20656e640a200a656e640a0a66756e6374696f6e20646f6661646528290a2066616465706572633d6d696e286661")
    (hex 1536 "6465706572632c31290a20666f7220633d302c313520646f0a202070616c28632c666164657461626c655b632b315d5b666c722866616465706572632a31362b31295d2c31290a20656e640a656e640a0a66756e6374696f6e205f7570646174652829200a20742b3d310a200a20626c696e6b742b3d310a200a206966206d6f64653d3d2267616d6522207468656e0a20207570646174655f67616d6528290a20656c73656966206d6f64653d3d22737461727422207468656e0a20207570646174655f737461727428290a20656c73656966206d6f64653d3d22776176657465787422207468656e0a20207570646174655f776176657465787428290a2065")
    (hex 1792 "6c73656966206d6f64653d3d226f76657222207468656e0a20207570646174655f6f76657228290a20656c73656966206d6f64653d3d2277696e22207468656e0a20207570646174655f77696e28290a20656e640a200a656e640a0a66756e6374696f6e205f6472617728290a20646f7368616b6528290a200a206966206d6f64653d3d2267616d6522207468656e0a2020647261775f67616d6528290a20656c73656966206d6f64653d3d22737461727422207468656e0a2020647261775f737461727428290a20656c73656966206d6f64653d3d22776176657465787422207468656e0a2020647261775f776176657465787428290a20656c7365696620")
    (hex 2048 "6d6f64653d3d226f76657222207468656e0a2020647261775f6f76657228290a20656c73656966206d6f64653d3d2277696e22207468656e0a2020647261775f77696e28290a20656e640a200a2063616d65726128290a207072696e742864656275672c322c392c37290a0a656e640a0a66756e6374696f6e20737461727473637265656e28290a206d616b65737461727328290a206d6f64653d227374617274220a206d757369632837290a656e640a0a66756e6374696f6e20737461727467616d6528290a20743d300a20776176653d300a206c617374776176653d390a206e6578747761766528290a200a20736869703d6d616b6573707228290a2073")
    (hex 2304 "6869702e783d36300a20736869702e793d39300a20736869702e73783d300a20736869702e73793d300a20736869702e7370723d320a2020200a20666c616d657370723d350a200a2062756c74696d65723d300a200a206d757a7a6c653d300a200a2073636f72653d300a20636865723d300a200a206c697665733d340a20696e76756c3d300a200a206174746163667265713d36300a2066697265667265713d32300a206e657874666972653d300a200a206d616b65737461727328290a20200a2062756c733d7b7d0a206562756c733d7b7d0a200a20656e656d6965733d7b7d0a200a2070617274733d7b7d0a200a20736877617665733d7b7d0a200a20")
    (hex 2560 "7069636b7570733d7b7d0a200a20666c6f6174733d7b7d0a656e640a0a2d2d3e380a2d2d20746f6f6c730a0a66756e6374696f6e206d616b65737461727328290a2073746172733d7b7d200a20666f7220693d312c31303020646f0a20206c6f63616c206e6577737461723d7b7d0a20206e6577737461722e783d666c7228726e642831323829290a20206e6577737461722e793d666c7228726e642831323829290a20206e6577737461722e7370643d726e6428312e35292b302e350a20206164642873746172732c6e657773746172290a20656e64200a656e640a0a66756e6374696f6e20737461726669656c6428290a200a20666f7220693d312c2373")
    (hex 2816 "7461727320646f0a20206c6f63616c206d79737461723d73746172735b695d0a20206c6f63616c2073636f6c3d360a20200a20206966206d79737461722e7370643c31207468656e0a20202073636f6c3d310a2020656c73656966206d79737461722e7370643c312e35207468656e0a20202073636f6c3d31330a2020656e642020200a20200a202070736574286d79737461722e782c6d79737461722e792c73636f6c290a20656e640a656e640a0a66756e6374696f6e20616e696d617465737461727328737064290a206966207370643d3d6e696c207468656e0a20207370643d310a20656e640a200a20666f7220693d312c23737461727320646f0a20")
    (hex 3072 "206c6f63616c206d79737461723d73746172735b695d0a20206d79737461722e793d6d79737461722e792b6d79737461722e7370642a7370640a20206966206d79737461722e793e313238207468656e0a2020206d79737461722e793d6d79737461722e792d3132380a2020656e640a20656e640a0a656e640a0a66756e6374696f6e20626c696e6b28290a206c6f63616c2062616e696d3d7b352c352c352c352c352c352c352c352c352c352c352c362c362c372c372c362c362c357d0a200a20696620626c696e6b743e2362616e696d207468656e0a2020626c696e6b743d310a20656e640a0a2072657475726e2062616e696d5b626c696e6b745d0a65")
    (hex 3328 "6e640a0a66756e6374696f6e206472776f75746c696e65286d79737072290a20737072286d797370722e7370722c6d797370722e782b312c6d797370722e792c6d797370722e737072772c6d797370722e73707268290a20737072286d797370722e7370722c6d797370722e782d312c6d797370722e792c6d797370722e737072772c6d797370722e73707268290a20737072286d797370722e7370722c6d797370722e782c6d797370722e792b312c6d797370722e737072772c6d797370722e73707268290a20737072286d797370722e7370722c6d797370722e782c6d797370722e792d312c6d797370722e737072772c6d797370722e73707268290a65")
    (hex 3584 "6e640a0a66756e6374696f6e206472776d79737072286d79737072290a206c6f63616c20737072783d6d797370722e780a206c6f63616c20737072793d6d797370722e790a200a206966206d797370722e7368616b653e30207468656e0a20206d797370722e7368616b652d3d310a20206966207425343c32207468656e0a202020737072782b3d310a2020656e640a20656e640a206966206d797370722e62756c6d6f6465207468656e0a2020737072782d3d320a2020737072792d3d320a20656e640a200a20737072286d797370722e7370722c737072782c737072792c6d797370722e737072772c6d797370722e73707268290a656e640a0a66756e63")
    (hex 3840 "74696f6e20636f6c28612c62290a20696620612e67686f7374206f7220622e67686f7374207468656e200a202072657475726e2066616c73650a20656e640a0a206c6f63616c20615f6c6566743d612e780a206c6f63616c20615f746f703d612e790a206c6f63616c20615f72696768743d612e782b612e636f6c772d310a206c6f63616c20615f626f74746f6d3d612e792b612e636f6c682d310a200a206c6f63616c20625f6c6566743d622e780a206c6f63616c20625f746f703d622e790a206c6f63616c20625f72696768743d622e782b622e636f6c772d310a206c6f63616c20625f626f74746f6d3d622e792b622e636f6c682d310a0a2069662061")
    (hex 4096 "5f746f703e625f626f74746f6d207468656e2072657475726e2066616c736520656e640a20696620625f746f703e615f626f74746f6d207468656e2072657475726e2066616c736520656e640a20696620615f6c6566743e625f7269676874207468656e2072657475726e2066616c736520656e640a20696620625f6c6566743e615f7269676874207468656e2072657475726e2066616c736520656e640a200a2072657475726e20747275650a656e640a0a66756e6374696f6e206578706c6f646528657870782c657870792c6973626c7565290a200a206c6f63616c206d79703d7b7d0a206d79702e783d657870780a206d79702e793d657870790a200a")
    (hex 4352 "206d79702e73783d300a206d79702e73793d300a200a206d79702e6167653d300a206d79702e73697a653d31300a206d79702e6d61786167653d300a206d79702e626c75653d6973626c75650a200a206164642870617274732c6d7970290a0920200a20666f7220693d312c333020646f0a09206c6f63616c206d79703d7b7d0a09206d79702e783d657870780a09206d79702e793d657870790a09200a09206d79702e73783d726e6428292a362d330a09206d79702e73793d726e6428292a362d330a09200a09206d79702e6167653d726e642832290a09206d79702e73697a653d312b726e642834290a09206d79702e6d61786167653d31302b726e6428")
    (hex 4608 "3130290a09206d79702e626c75653d6973626c75650a09200a09206164642870617274732c6d7970290a20656e640a200a20666f7220693d312c323020646f0a09206c6f63616c206d79703d7b7d0a09206d79702e783d657870780a09206d79702e793d657870790a09200a09206d79702e73783d28726e6428292d302e35292a31300a09206d79702e73793d28726e6428292d302e35292a31300a09200a09206d79702e6167653d726e642832290a09206d79702e73697a653d312b726e642834290a09206d79702e6d61786167653d31302b726e64283130290a09206d79702e626c75653d6973626c75650a09206d79702e737061726b3d747275650a09")
    (hex 4864 "200a09206164642870617274732c6d7970290a20656e640a200a206269675f73687761766528657870782c65787079290a200a656e640a0a66756e6374696f6e206269676578706c6f646528657870782c65787079290a200a206c6f63616c206d79703d7b7d0a206d79702e783d657870780a206d79702e793d657870790a200a206d79702e73783d300a206d79702e73793d300a200a206d79702e6167653d300a206d79702e73697a653d32350a206d79702e6d61786167653d300a200a206164642870617274732c6d7970290a0920200a20666f7220693d312c363020646f0a09206c6f63616c206d79703d7b7d0a09206d79702e783d657870780a0920")
    (hex 5120 "6d79702e793d657870790a09200a09206d79702e73783d726e6428292a31322d360a09206d79702e73793d726e6428292a31322d360a09200a09206d79702e6167653d726e642832290a09206d79702e73697a653d312b726e642836290a09206d79702e6d61786167653d32302b726e64283230290a09200a09206164642870617274732c6d7970290a20656e640a200a20666f7220693d312c31303020646f0a09206c6f63616c206d79703d7b7d0a09206d79702e783d657870780a09206d79702e793d657870790a09200a09206d79702e73783d28726e6428292d302e35292a33300a09206d79702e73793d28726e6428292d302e35292a33300a09200a")
    (hex 5376 "09206d79702e6167653d726e642832290a09206d79702e73697a653d312b726e642834290a09206d79702e6d61786167653d32302b726e64283230290a09206d79702e737061726b3d747275650a09200a09206164642870617274732c6d7970290a20656e640a200a206269675f73687761766528657870782c65787079290a200a656e640a0a66756e6374696f6e20706167655f7265642870616765290a206c6f63616c20636f6c3d370a200a20696620706167653e35207468656e0a2020636f6c3d31300a20656e640a20696620706167653e37207468656e0a2020636f6c3d390a20656e640a20696620706167653e3130207468656e0a2020636f6c3d")
    (hex 5632 "380a20656e640a20696620706167653e3132207468656e0a2020636f6c3d320a20656e640a20696620706167653e3135207468656e0a2020636f6c3d350a20656e640a200a2072657475726e20636f6c0a656e640a0a66756e6374696f6e20706167655f626c75652870616765290a206c6f63616c20636f6c3d370a200a20696620706167653e35207468656e0a2020636f6c3d360a20656e640a20696620706167653e37207468656e0a2020636f6c3d31320a20656e640a20696620706167653e3130207468656e0a2020636f6c3d31330a20656e640a20696620706167653e3132207468656e0a2020636f6c3d310a20656e640a20696620706167653e31")
    (hex 5888 "35207468656e0a2020636f6c3d310a20656e640a200a2072657475726e20636f6c0a656e640a0a66756e6374696f6e20736d6f6c5f736877617665287368782c7368792c7368636f6c290a206966207368636f6c3d3d6e696c207468656e0a20207368636f6c3d390a20656e64200a206c6f63616c206d7973773d7b7d0a206d7973772e783d7368780a206d7973772e793d7368790a206d7973772e723d330a206d7973772e74723d360a206d7973772e636f6c3d7368636f6c0a206d7973772e73706565643d310a2061646428736877617665732c6d797377290a656e640a0a66756e6374696f6e206269675f736877617665287368782c736879290a206c")
    (hex 6144 "6f63616c206d7973773d7b7d0a206d7973772e783d7368780a206d7973772e793d7368790a206d7973772e723d330a206d7973772e74723d32350a206d7973772e636f6c3d370a206d7973772e73706565643d332e350a2061646428736877617665732c6d797377290a656e640a0a66756e6374696f6e20736d6f6c5f737061726b2873782c7379290a202d2d666f7220693d312c3220646f0a206c6f63616c206d79703d7b7d0a206d79702e783d73780a206d79702e793d73790a200a206d79702e73783d28726e6428292d302e35292a380a206d79702e73793d28726e6428292d31292a330a200a206d79702e6167653d726e642832290a206d79702e73")
    (hex 6400 "697a653d312b726e642834290a206d79702e6d61786167653d31302b726e64283130290a206d79702e626c75653d6973626c75650a206d79702e737061726b3d747275650a200a206164642870617274732c6d7970290a202d2d656e640a656e640a0a66756e6374696f6e206d616b6573707228290a206c6f63616c206d797370723d7b7d0a206d797370722e783d300a206d797370722e793d300a206d797370722e73783d300a206d797370722e73793d300a200a206d797370722e666c6173683d300a206d797370722e7368616b653d300a200a206d797370722e616e696672616d653d310a206d797370722e7370723d300a206d797370722e73707277")
    (hex 6656 "3d310a206d797370722e737072683d310a206d797370722e636f6c773d380a206d797370722e636f6c683d380a200a2072657475726e206d797370720a656e640a0a66756e6374696f6e20646f7368616b6528290a0a206c6f63616c207368616b65783d726e64287368616b65292d287368616b652f32290a206c6f63616c207368616b65793d726e64287368616b65292d287368616b652f32290a200a2063616d657261287368616b65782c7368616b6579290a200a206966207368616b653e3130207468656e0a20207368616b652a3d302e390a20656c73650a20207368616b652d3d310a20206966207368616b653c31207468656e0a2020207368616b")
    (hex 6912 "653d300a2020656e640a20656e640a656e640a0a66756e6374696f6e20706f70666c6f617428666c7478742c666c782c666c79290a206c6f63616c20666c3d7b7d0a20666c2e783d666c780a20666c2e793d666c790a20666c2e7478743d666c7478740a20666c2e6167653d300a2061646428666c6f6174732c666c290a656e640a0a66756e6374696f6e20637072696e74287478742c782c792c63290a207072696e74287478742c782d237478742a322c792c63290a656e640a0a0a2d2d3e380a2d2d7570646174650a0a66756e6374696f6e207570646174655f67616d6528290a202d2d636f6e74726f6c730a20736869702e73783d300a20736869702e")
    (hex 7168 "73793d300a20736869702e7370723d320a200a2069662062746e283029207468656e0a2020736869702e73783d2d320a2020736869702e7370723d310a20656e640a2069662062746e283129207468656e0a2020736869702e73783d320a2020736869702e7370723d330a20656e640a2069662062746e283229207468656e0a2020736869702e73793d2d320a20656e640a2069662062746e283329207468656e0a2020736869702e73793d320a20656e640a20200a2069662062746e70283429207468656e0a2020696620636865723e30207468656e0a20202063686572626f6d6228290a202020636865723d300a2020656c73650a202020736678283332")
    (hex 7424 "290a2020656e640a20656e640a200a2069662062746e283529207468656e0a202069662062756c74696d65723c3d30207468656e0a0920206c6f63616c206e657762756c3d6d616b6573707228290a0920206e657762756c2e783d736869702e782b310a0920206e657762756c2e793d736869702e792d330a0920206e657762756c2e7370723d31360a0920206e657762756c2e636f6c773d360a0920206e657762756c2e73793d2d340a0920206e657762756c2e646d673d310a0920206164642862756c732c6e657762756c290a0920200a0920207366782830290a0920206d757a7a6c653d350a09202062756c74696d65723d340a2020656e640a20656e")
    (hex 7680 "640a2062756c74696d65722d3d310a200a202d2d6d6f76696e672074686520736869700a20736869702e782b3d736869702e73780a20736869702e792b3d736869702e73790a200a202d2d636865636b696e67206966207765206869742074686520656467650a20696620736869702e783e313230207468656e0a2020736869702e783d3132300a20656e640a20696620736869702e783c30207468656e0a2020736869702e783d300a20656e640a20696620736869702e793c30207468656e0a2020736869702e793d300a20656e640a20696620736869702e793e313230207468656e0a2020736869702e793d3132300a20656e640a200a202d2d6d6f7665")
    (hex 7936 "207468652062756c6c6574730a20666f72206d7962756c20696e20616c6c2862756c732920646f0a20206d6f7665286d7962756c290a20206966206d7962756c2e793c2d38207468656e0a20202064656c2862756c732c6d7962756c290a2020656e640a20656e640a200a202d2d6d6f766520746865206562756c730a20666f72206d796562756c20696e20616c6c286562756c732920646f0a20206d6f7665286d796562756c290a2020616e696d617465286d796562756c290a20206966206d796562756c2e793e313238206f72206d796562756c2e783c2d38206f72206d796562756c2e783e313238206f72206d796562756c2e793c2d38207468656e0a")
    (hex 8192 "20202064656c286562756c732c6d796562756c290a2020656e640a20656e64200a200a202d2d6d6f766520746865207069636b7570730a20666f72206d797069636b20696e20616c6c287069636b7570732920646f0a20206d6f7665286d797069636b290a20206966206d797069636b2e793e313238207468656e0a20202064656c287069636b7570732c6d797069636b290a2020656e640a20656e64200a200a202d2d6d6f76696e6720656e656d696573200a20666f72206d79656e20696e20616c6c28656e656d6965732920646f0a20202d2d656e656d79206d697373696f6e0a2020646f656e656d79286d79656e290a20200a20202d2d656e656d7920")
    (hex 8448 "616e696d6174696f6e0a2020616e696d617465286d79656e290a202020200a20202d2d656e656d79206c656176696e672073637265656e0a20206966206d79656e2e6d697373696f6e213d22666c79696e22207468656e200a2020206966206d79656e2e793e313238206f72206d79656e2e783c2d38206f72206d79656e2e783e313238207468656e0a2020202064656c28656e656d6965732c6d79656e290a202020656e640a2020656e640a20656e640a200a202d2d636f6c6c6973696f6e20656e656d7920782062756c6c6574730a20666f72206d79656e20696e20616c6c28656e656d6965732920646f0a2020666f72206d7962756c20696e20616c6c")
    (hex 8704 "2862756c732920646f0a202020696620636f6c286d79656e2c6d7962756c29207468656e0a2020202064656c2862756c732c6d7962756c290a20202020736d6f6c5f736877617665286d7962756c2e782b342c6d7962756c2e792b34290a20202020736d6f6c5f737061726b286d79656e2e782b342c6d79656e2e792b34290a202020206966206d79656e2e6d697373696f6e213d22666c79696e22207468656e0a20202020206d79656e2e68702d3d6d7962756c2e646d670a20202020656e640a202020207366782833290a202020206966206d79656e2e626f7373207468656e0a20202020206d79656e2e666c6173683d350a20202020656c73650a2020")
    (hex 8960 "2020206d79656e2e666c6173683d320a20202020656e640a202020206966206d79656e2e68703c3d30207468656e0a20202020206b696c6c656e286d79656e290a20202020656e640a202020656e640a2020656e640a20656e640a200a202d2d636f6c6c6973696f6e206562756c7320782062756c6c6574730a20666f72206d7962756c20696e20616c6c2862756c732920646f0a20206966206d7962756c2e7370723d3d3137207468656e0a092020666f72206d796562756c20696e20616c6c286562756c732920646f0a09202020696620636f6c286d796562756c2c6d7962756c29207468656e0a092020202064656c286562756c732c6d796562756c29")
    (hex 9216 "0a092020202073636f72652b3d350a0920202020736d6f6c5f736877617665286562756c732e782c6562756c732e792c38290a09202020656e640a092020656e640a2020656e640a20656e640a200a202d2d636f6c6c6973696f6e2073686970207820656e656d6965730a20696620696e76756c3c3d30207468656e0a0920666f72206d79656e20696e20616c6c28656e656d6965732920646f0a092020696620636f6c286d79656e2c7368697029207468656e0a202020206578706c6f646528736869702e782b342c736869702e792b342c74727565290a092020206c697665732d3d310a092020207366782831290a092020207368616b653d31320a0920")
    (hex 9472 "2020696e76756c3d36300a20202020736869702e783d36300a20202020736869702e793d3130300a20202020666c6173683d330a092020656e640a0920656e640a20656c73650a2020696e76756c2d3d310a20656e640a200a202d2d636f6c6c6973696f6e20736869702078206562756c730a20696620696e76756c3c3d30207468656e0a0920666f72206d796562756c20696e20616c6c286562756c732920646f0a092020696620636f6c286d796562756c2c7368697029207468656e0a202020206578706c6f646528736869702e782b342c736869702e792b342c74727565290a092020206c697665732d3d310a092020207368616b653d31320a092020")
    (hex 9728 "207366782831290a09202020696e76756c3d36300a20202020736869702e783d36300a20202020736869702e793d3130300a20202020666c6173683d330a092020656e640a0920656e640a20656e640a200a202d2d636f6c6c6973696f6e207069636b7570207820736869700a20666f72206d797069636b20696e20616c6c287069636b7570732920646f0a2020696620636f6c286d797069636b2c7368697029207468656e0a20202064656c287069636b7570732c6d797069636b290a202020706c6f676963286d797069636b290a2020656e640a20656e640a200a200a206966206c697665733c3d30207468656e0a20206d6f64653d226f766572220a20")
    (hex 9984 "206c6f636b6f75743d742b33300a20206d757369632836290a202072657475726e0a20656e640a200a202d2d7069636b696e670a207069636b74696d657228290a200a202d2d616e696d61746520666c616d650a20666c616d657370723d666c616d657370722b310a20696620666c616d657370723e39207468656e0a2020666c616d657370723d350a20656e640a200a202d2d616e696d617465206d756c6c7a6520666c6173680a206966206d757a7a6c653e30207468656e0a20206d757a7a6c653d6d757a7a6c652d310a20656e640a20200a206966206d6f64653d3d22776176657465787422207468656e0a2020616e696d6174657374617273283229")
    (hex 10240 "0a20656c73650a2020616e696d617465737461727328290a20656e640a200a202d2d636865636b2069662077617665206f7665720a206966206d6f64653d3d2267616d652220616e642023656e656d6965733d3d30207468656e0a20206562756c733d7b7d0a20206e6578747761766528290a20656e640a200a656e640a0a66756e6374696f6e207570646174655f737461727428290a20616e696d617465737461727328302e34290a200a2069662062746e2834293d3d66616c736520616e642062746e2835293d3d66616c7365207468656e0a202062746e72656c65617365643d747275650a20656e640a0a2069662062746e72656c6561736564207468")
    (hex 10496 "656e0a202069662062746e70283429206f722062746e70283529207468656e0a202020737461727467616d6528290a20202062746e72656c65617365643d66616c73650a2020656e640a20656e640a656e640a0a66756e6374696f6e207570646174655f6f76657228290a20696620743c6c6f636b6f7574207468656e0a202072657475726e0a20656e640a200a2069662062746e2834293d3d66616c736520616e642062746e2835293d3d66616c7365207468656e0a202062746e72656c65617365643d747275650a20656e640a0a2069662062746e72656c6561736564207468656e0a202069662062746e70283429206f722062746e7028352920746865")
    (hex 10752 "6e0a20202069662073636f72653e6869676873636f7265207468656e0a202020206869676873636f72653d73636f72650a202020206473657428302c73636f7265290a202020656e640a202020737461727473637265656e28290a20202062746e72656c65617365643d66616c73650a2020656e640a20656e640a656e640a0a66756e6374696f6e207570646174655f77696e28290a20696620743c6c6f636b6f7574207468656e0a202072657475726e0a20656e640a200a2069662062746e2834293d3d66616c736520616e642062746e2835293d3d66616c7365207468656e0a202062746e72656c65617365643d747275650a20656e640a0a2069662062")
    (hex 11008 "746e72656c6561736564207468656e0a202069662062746e70283429206f722062746e70283529207468656e0a20202069662073636f72653e6869676873636f7265207468656e0a202020206869676873636f72653d73636f72650a202020206473657428302c73636f7265290a202020656e640a202020737461727473637265656e28290a20202062746e72656c65617365643d66616c73650a2020656e640a20656e640a656e640a0a66756e6374696f6e207570646174655f776176657465787428290a207570646174655f67616d6528290a207761766574696d652d3d310a206966207761766574696d653c3d30207468656e0a20206d6f64653d2267")
    (hex 11264 "616d65220a2020737061776e7761766528290a20656e640a656e640a2d2d3e380a2d2d20647261770a0a66756e6374696f6e20647261775f67616d6528290a20696620666c6173683e30207468656e0a2020666c6173682d3d310a2020636c732832290a20656c73650a2020636c732830290a20656e640a200a20737461726669656c6428290a0a206966206c697665733e30207468656e0a0920696620696e76756c3c3d30207468656e0a0920206472776d797370722873686970290a09202073707228666c616d657370722c736869702e782c736869702e792b38290a0920656c73650a0920202d2d696e76756c2073746174650a09202069662073696e")
    (hex 11520 "28742f35293c302e31207468656e0a092020206472776d797370722873686970290a0920202073707228666c616d657370722c736869702e782c736869702e792b38290a092020656e640a0920656e640a20656e640a200a202d2d64726177696e67207069636b7570730a20666f72206d797069636b20696e20616c6c287069636b7570732920646f0a20206c6f63616c206d79636f6c3d370a20206966207425343c32207468656e0a2020206d79636f6c3d31340a2020656e640a2020666f7220693d312c313520646f0a20202070616c28692c6d79636f6c290a2020656e640a20206472776f75746c696e65286d797069636b290a202070616c28290a20")
    (hex 11776 "206472776d79737072286d797069636b290a20656e640a200a202d2d64726177696e6720656e656d6965730a20666f72206d79656e20696e20616c6c28656e656d6965732920646f0a20206966206d79656e2e666c6173683e30207468656e0a2020206966207425343c32207468656e0a2020202070616c28332c38290a2020202070616c2831312c3134290a202020656e640a2020206d79656e2e666c6173682d3d310a2020206966206d79656e2e626f7373207468656e0a202020206d79656e2e7370723d38300a202020656c73650a20202020666f7220693d312c313520646f0a202020202070616c28692c37290a20202020656e640a202020656e64")
    (hex 12032 "0a2020656e640a20206472776d79737072286d79656e290a202070616c28290a20656e640a20200a202d2d64726177696e672062756c6c6574730a20666f72206d7962756c20696e20616c6c2862756c732920646f0a20206472776d79737072286d7962756c290a20656e640a200a206966206d757a7a6c653e30207468656e0a20206369726366696c6c28736869702e782b332c736869702e792d322c6d757a7a6c652c37290a20206369726366696c6c28736869702e782b342c736869702e792d322c6d757a7a6c652c37290a20656e640a200a202d2d64726177696e6720736877617665730a20666f72206d79737720696e20616c6c28736877617665")
    (hex 12288 "732920646f0a202063697263286d7973772e782c6d7973772e792c6d7973772e722c6d7973772e636f6c290a20206d7973772e722b3d6d7973772e73706565640a20206966206d7973772e723e6d7973772e7472207468656e0a20202064656c28736877617665732c6d797377290a2020656e640a20656e640a200a202d2d64726177696e67207061727469636c65730a20666f72206d797020696e20616c6c2870617274732920646f0a20206c6f63616c2070633d370a0a20206966206d79702e626c7565207468656e0a20202070633d706167655f626c7565286d79702e616765290a2020656c73650a20202070633d706167655f726564286d79702e61")
    (hex 12544 "6765290a2020656e640a20200a20206966206d79702e737061726b207468656e0a20202070736574286d79702e782c6d79702e792c37290a2020656c73650a2020206369726366696c6c286d79702e782c6d79702e792c6d79702e73697a652c7063290a2020656e640a20200a20206d79702e782b3d6d79702e73780a20206d79702e792b3d6d79702e73790a20200a20206d79702e73783d6d79702e73782a302e38350a20206d79702e73793d6d79702e73792a302e38350a20200a20206d79702e6167652b3d310a20200a20206966206d79702e6167653e6d79702e6d6178616765207468656e0a2020206d79702e73697a652d3d302e350a2020206966")
    (hex 12800 "206d79702e73697a653c30207468656e0a2020202064656c2870617274732c6d7970290a202020656e640a2020656e640a20656e640a200a202d2d64726177696e67206562756c730a20666f72206d796562756c20696e20616c6c286562756c732920646f0a20206472776d79737072286d796562756c290a20656e640a200a202d2d666c6f6174730a20666f72206d79666c20696e20616c6c28666c6f6174732920646f0a20206c6f63616c206d79636f6c3d370a20206966207425343c32207468656e0a2020206d79636f6c3d380a2020656e640a2020637072696e74286d79666c2e7478742c6d79666c2e782c6d79666c2e792c6d79636f6c290a2020")
    (hex 13056 "6d79666c2e792d3d302e350a20206d79666c2e6167652b3d310a20206966206d79666c2e6167653e3630207468656e0a20202064656c28666c6f6174732c6d79666c290a2020656e640a20656e640a200a207072696e74282273636f72653a222e2e6d616b6573636f72652873636f7265292c34302c322c3132290a200a20666f7220693d312c3420646f0a20206966206c697665733e3d69207468656e0a2020207370722833372c692a392d382c31290a2020656c73650a2020207370722833382c692a392d382c31290a2020656e64200a20656e640a0a207370722834382c3130382c31290a207072696e7428636865722c3131382c322c3134290a200a")
    (hex 13312 "202d2d7072696e74282362756c732c352c352c37290a656e640a0a66756e6374696f6e206d616b6573636f72652876616c290a2069662076616c3d3d30207468656e0a202072657475726e202230220a20656e640a2072657475726e2076616c2e2e223030220a656e640a0a66756e6374696f6e20647261775f737461727428290a20636c732830290a20737461726669656c6428290a207072696e742876657273696f6e2c312c312c31290a0a207370722832312c7065656b6572782c32382b73696e2874696d6528292f332e35292a3420290a2069662073696e2874696d6528292f332e35293e302e35207468656e0a20207065656b6572783d33302b72")
    (hex 13568 "6e64283630290a20656e640a2020200a20737072283231322c31372c33302c31322c32290a20637072696e74282273686f7274207368776176652073686d7570222c36342c34352c36290a200a206966206869676873636f72653e30207468656e0a2020637072696e7428226869676873636f72653a222c36342c36332c3132290a2020637072696e74286d616b6573636f7265286869676873636f7265292c36342c36392c3132290a20656e640a0a20637072696e742822707265737320616e79206b657920746f207374617274222c36342c39302c626c696e6b2829290a200a207265637466696c6c28302c3131352c3132382c3132382c31290a206370")
    (hex 13824 "72696e7428226c6561726e20686f7720746f206d616b6520746869732067616d6521222c36342c3131362c3132290a20637072696e7428226269742e6c792f73686d75706d65222c36342c3132322c3132290a200a656e640a0a66756e6374696f6e20647261775f6f76657228290a20647261775f67616d6528290a20637072696e74282267616d65206f766572222c36342c34302c3829200a200a20637072696e74282273636f72653a222e2e6d616b6573636f72652873636f7265292c36342c36302c3132290a2069662073636f72653e6869676873636f7265207468656e0a20206c6f63616c20633d370a20206966207425343c32207468656e0a2020")
    (hex 14080 "20633d31300a2020656e640a2020637072696e7428226e6577206869676873636f726521222c36342c36362c6329200a20656e640a200a20637072696e742822707265737320616e79206b657920746f20636f6e74696e7565222c36342c39302c626c696e6b2829290a656e640a0a66756e6374696f6e20647261775f77696e28290a20647261775f67616d6528290a20637072696e742822636f6e67726174756c6174696f6e73222c36342c34302c3132290a20637072696e74282273636f72653a222e2e6d616b6573636f72652873636f7265292c36342c36302c3132290a0a2069662073636f72653e6869676873636f7265207468656e0a20206c6f63")
    (hex 14336 "616c20633d370a20206966207425343c32207468656e0a202020633d31300a2020656e640a2020637072696e7428226e6577206869676873636f726521222c36342c36362c6329200a20656e640a0a20637072696e742822707265737320616e79206b657920746f20636f6e74696e7565222c36342c39302c626c696e6b2829290a656e640a0a66756e6374696f6e20647261775f776176657465787428290a20647261775f67616d6528290a20696620776176653d3d6c61737477617665207468656e0a2020637072696e74282266696e616c207761766521222c36342c34302c626c696e6b2829290a20656c73650a2020637072696e7428227761766520")
    (hex 14592 "222e2e776176652e2e22206f6620222e2e6c617374776176652c36342c34302c626c696e6b2829290a20656e640a656e640a2d2d3e380a2d2d20776176657320616e6420656e656d6965730a0a66756e6374696f6e20737061776e7761766528290a20696620776176653c6c61737477617665207468656e0a2020736678283238290a20656c73650a20206d75736963283130290a20656e640a200a20696620776176653d3d31207468656e0a20202d2d737061636520696e7661646572730a20206174746163667265713d36300a202066697265667265713d32300a2020706c6163656e73287b0a2020207b302c312c312c312c312c312c312c312c312c30")
    (hex 14848 "7d2c0a2020207b302c312c312c312c312c312c312c312c312c307d2c0a2020207b302c312c312c312c312c312c312c312c312c307d2c0a2020207b302c312c312c312c312c312c312c312c312c307d0a20207d290a20656c7365696620776176653d3d32207468656e0a20202d2d726564207475746f7269616c0a20206174746163667265713d36300a202066697265667265713d32300a2020706c6163656e73287b0a2020207b312c312c322c322c312c312c322c322c312c317d2c0a2020207b312c312c322c322c312c312c322c322c312c317d2c0a2020207b312c312c322c322c322c322c322c322c312c317d2c0a2020207b312c312c322c322c322c")
    (hex 15104 "322c322c322c312c317d0a20207d290a20656c7365696620776176653d3d33207468656e0a20202d2d77616c6c206f66207265640a20206174746163667265713d35300a202066697265667265713d32300a2020706c6163656e73287b0a2020207b312c312c322c322c312c312c322c322c312c317d2c0a2020207b312c312c322c322c322c322c322c322c312c317d2c0a2020207b322c322c322c322c322c322c322c322c322c327d2c0a2020207b322c322c322c322c322c322c322c322c322c327d0a20207d290a20656c7365696620776176653d3d34207468656e0a20202d2d7370696e207475746f7269616c0a20206174746163667265713d35300a")
    (hex 15360 "202066697265667265713d31350a2020706c6163656e73287b0a2020207b332c332c302c312c312c312c312c302c332c337d2c0a2020207b332c332c302c312c312c312c312c302c332c337d2c0a2020207b332c332c302c312c312c312c312c302c332c337d2c0a2020207b332c332c302c312c312c312c312c302c332c337d0a20207d290a20656c7365696620776176653d3d35207468656e0a20202d2d63686573730a20206174746163667265713d35300a202066697265667265713d31350a2020706c6163656e73287b0a2020207b332c312c332c312c322c322c312c332c312c337d2c0a2020207b312c332c312c322c312c312c322c312c332c317d")
    (hex 15616 "2c0a2020207b332c312c332c312c322c322c312c332c312c337d2c0a2020207b312c332c312c322c312c312c322c312c332c317d0a20207d290a20656c7365696620776176653d3d36207468656e0a20202d2d79656c6c6f77207475746f7269616c0a20206174746163667265713d34300a202066697265667265713d31300a2020706c6163656e73287b0a2020207b322c322c322c302c342c302c302c322c322c327d2c0a2020207b322c322c302c302c302c302c302c302c322c327d2c0a2020207b312c312c302c312c312c312c312c302c312c317d2c0a2020207b312c312c302c312c312c312c312c302c312c317d0a20207d290a20200a20656c7365")
    (hex 15872 "696620776176653d3d37207468656e0a20202d2d646f75626c652079656c6c6f770a20206174746163667265713d34300a202066697265667265713d31300a2020706c6163656e73287b0a2020207b332c332c302c312c312c312c312c302c332c337d2c0a2020207b342c302c302c322c322c322c322c302c342c307d2c0a2020207b302c302c302c322c312c312c322c302c302c307d2c0a2020207b312c312c302c312c312c312c312c302c312c317d0a20207d290a20656c7365696620776176653d3d38207468656e0a20202d2d68656c6c0a20206174746163667265713d33300a202066697265667265713d31300a2020706c6163656e73287b0a2020")
    (hex 16128 "207b302c302c312c312c312c312c312c312c302c307d2c0a2020207b332c332c312c312c312c312c312c312c332c337d2c0a2020207b332c332c322c322c322c322c322c322c332c337d2c0a2020207b332c332c322c322c322c322c322c322c332c337d0a20207d290a20656c7365696620776176653d3d39207468656e0a20202d2d626f73730a20206174746163667265713d36300a202066697265667265713d32300a2020706c6163656e73287b0a2020207b302c302c302c302c352c302c302c302c302c307d2c0a2020207b302c302c302c302c302c302c302c302c302c307d2c0a2020207b302c302c302c302c302c302c302c302c302c307d2c0a20")
    (hex 16384 "20207b302c302c302c302c302c302c302c302c302c307d0a20207d290a20656e6420200a656e640a0a66756e6374696f6e20706c6163656e73286c766c290a0a20666f7220793d312c3420646f0a20206c6f63616c206d796c696e653d6c766c5b795d0a2020666f7220783d312c313020646f0a2020206966206d796c696e655b785d213d30207468656e0a20202020737061776e656e286d796c696e655b785d2c782a31322d362c342b792a31322c782a33290a202020656e640a2020656e640a20656e640a200a656e640a0a66756e6374696f6e206e6578747761766528290a20776176652b3d310a200a20696620776176653e6c617374776176652074")
    (hex 16640 "68656e0a20206d6f64653d2277696e220a20206c6f636b6f75743d742b33300a20206d757369632834290a20656c73650a2020696620776176653d3d31207468656e0a2020206d757369632830290a2020656c73650a2020206d7573696328332920200a2020656e640a20200a20206d6f64653d227761766574657874220a20207761766574696d653d38300a20656e640a0a656e640a0a66756e6374696f6e20737061776e656e28656e747970652c656e782c656e792c656e77616974290a206c6f63616c206d79656e3d6d616b6573707228290a206d79656e2e783d656e782a312e32352d31360a206d79656e2e793d656e792d36360a200a206d79656e")
    (hex 16896 "2e706f73783d656e780a206d79656e2e706f73793d656e790a200a206d79656e2e747970653d656e747970650a200a206d79656e2e776169743d656e776169740a0a206d79656e2e616e697370643d302e340a200a206d79656e2e6d697373696f6e3d22666c79696e220a200a20696620656e747970653d3d6e696c206f7220656e747970653d3d31207468656e0a20202d2d20677265656e20616c69656e0a20206d79656e2e7370723d32310a20206d79656e2e68703d330a20206d79656e2e616e693d7b32312c32322c32332c32347d0a20206d79656e2e73636f72653d310a20656c7365696620656e747970653d3d32207468656e0a20202d2d207265")
    (hex 17152 "6420666c616d65206775790a20206d79656e2e7370723d3134380a20206d79656e2e68703d320a20206d79656e2e616e693d7b3134382c3134397d0a20206d79656e2e73636f72653d320a20656c7365696620656e747970653d3d33207468656e0a20202d2d207370696e6e696e6720736869700a20206d79656e2e7370723d3138340a20206d79656e2e68703d340a20206d79656e2e616e693d7b3138342c3138352c3138362c3138377d0a20206d79656e2e73636f72653d330a20656c7365696620656e747970653d3d34207468656e0a20202d2d2079656c6c6f77206775790a20206d79656e2e7370723d3230380a20206d79656e2e68703d32300a20")
    (hex 17408 "206d79656e2e616e693d7b3230382c3231307d0a20206d79656e2e737072773d320a20206d79656e2e737072683d320a20206d79656e2e636f6c773d31360a20206d79656e2e636f6c683d31360a20206d79656e2e73636f72653d350a20656c7365696620656e747970653d3d35207468656e0a20206d79656e2e68703d3133300a20206d79656e2e7370723d38340a20206d79656e2e616e693d7b38342c38382c39322c38387d0a20206d79656e2e737072773d340a20206d79656e2e737072683d330a20206d79656e2e636f6c773d33320a20206d79656e2e636f6c683d32340a20200a20206d79656e2e783d34380a20206d79656e2e793d2d32340a20")
    (hex 17664 "206d79656e2e706f73783d34380a20206d79656e2e706f73793d32350a20200a20206d79656e2e626f73733d747275650a20656e640a20200a2061646428656e656d6965732c6d79656e290a656e640a2d2d3e380a2d2d6265686176696f720a0a66756e6374696f6e20646f656e656d79286d79656e290a206966206d79656e2e776169743e30207468656e0a20206d79656e2e776169742d3d310a202072657475726e0a20656e640a200a202d2d64656275673d6d79656e2e68700a200a206966206d79656e2e6d697373696f6e3d3d22666c79696e22207468656e0a20202d2d666c79696e6720696e0a20202d2d626173696320656173696e672066756e")
    (hex 17920 "6374696f6e0a20202d2d782b3d28746172676574782d78292f6e0a20200a20206c6f63616c2064783d286d79656e2e706f73782d6d79656e2e78292f370a20206c6f63616c2064793d286d79656e2e706f73792d6d79656e2e79292f370a20200a20206966206d79656e2e626f7373207468656e0a20202064793d6d696e2864792c31290a2020656e640a20206d79656e2e782b3d64780a20206d79656e2e792b3d64790a20200a2020696620616273286d79656e2e792d6d79656e2e706f7379293c302e37207468656e0a2020206d79656e2e793d6d79656e2e706f73790a2020206d79656e2e783d6d79656e2e706f73780a2020206966206d79656e2e62")
    (hex 18176 "6f7373207468656e0a20202020736678283530290a202020206d79656e2e7368616b653d32300a202020206d79656e2e776169743d32380a202020206d79656e2e6d697373696f6e3d22626f737331220a202020206d79656e2e7068626567696e3d740a202020656c73650a202020206d79656e2e6d697373696f6e3d2270726f746563220a202020656e640a2020656e640a20200a20656c73656966206d79656e2e6d697373696f6e3d3d2270726f74656322207468656e0a20202d2d2073746179696e67207075740a20656c73656966206d79656e2e6d697373696f6e3d3d22626f73733122207468656e0a2020626f737331286d79656e290a20656c73")
    (hex 18432 "656966206d79656e2e6d697373696f6e3d3d22626f73733222207468656e0a2020626f737332286d79656e290a20656c73656966206d79656e2e6d697373696f6e3d3d22626f73733322207468656e0a2020626f737333286d79656e290a20656c73656966206d79656e2e6d697373696f6e3d3d22626f73733422207468656e0a2020626f737334286d79656e290a20656c73656966206d79656e2e6d697373696f6e3d3d22626f73733522207468656e0a2020626f737335286d79656e290a20656c73656966206d79656e2e6d697373696f6e3d3d22617474616322207468656e20200a20202d2d2061747461630a20206966206d79656e2e747970653d3d")
    (hex 18688 "31207468656e0a2020202d2d677265656e206775790a2020206d79656e2e73793d312e370a2020206d79656e2e73783d73696e28742f3435290a2020200a2020202d2d206a75737420747765616b730a2020206966206d79656e2e783c3332207468656e0a202020206d79656e2e73782b3d312d286d79656e2e782f3332290a202020656e640a2020206966206d79656e2e783e3838207468656e0a202020206d79656e2e73782d3d286d79656e2e782d3838292f33320a202020656e640a2020656c73656966206d79656e2e747970653d3d32207468656e0a2020202d2d726564206775790a2020206d79656e2e73793d322e350a2020206d79656e2e7378")
    (hex 18944 "3d73696e28742f3230290a2020200a2020202d2d206a75737420747765616b730a2020206966206d79656e2e783c3332207468656e0a202020206d79656e2e73782b3d312d286d79656e2e782f3332290a202020656e640a2020206966206d79656e2e783e3838207468656e0a202020206d79656e2e73782d3d286d79656e2e782d3838292f33320a202020656e642020200a2020200a2020656c73656966206d79656e2e747970653d3d33207468656e0a2020202d2d7370696e6e7920736869700a2020206966206d79656e2e73783d3d30207468656e0a202020202d2d666c79696e6720646f776e0a202020206d79656e2e73793d320a20202020696620")
    (hex 19200 "736869702e793c3d6d79656e2e79207468656e0a20202020206d79656e2e73793d300a2020202020696620736869702e783c6d79656e2e78207468656e0a2020202020206d79656e2e73783d2d320a2020202020656c73650a2020202020206d79656e2e73783d320a2020202020656e640a20202020656e640a202020656e640a2020200a2020656c73656966206d79656e2e747970653d3d34207468656e0a2020202d2d79656c6c6f7720736869700a2020206d79656e2e73793d302e33350a2020206966206d79656e2e793e313130207468656e0a202020206d79656e2e73793d310a202020656c73650a202020200a20202020696620742532353d3d30")
    (hex 19456 "207468656e0a202020202066697265737072656164286d79656e2c382c312e332c726e642829290a20202020656e640a202020656e642020200a2020656e640a20200a20206d6f7665286d79656e290a20656e640a20200a656e640a0a66756e6374696f6e207069636b74696d657228290a206966206d6f6465213d2267616d6522207468656e0a202072657475726e0a20656e640a0a20696620743e6e65787466697265207468656e0a20207069636b6669726528290a20206e657874666972653d742b66697265667265712b726e64286669726566726571290a20656e640a200a2069662074256174746163667265713d3d30207468656e0a2020706963")
    (hex 19712 "6b617474616328290a20656e640a656e640a0a66756e6374696f6e207069636b617474616328290a206c6f63616c206d61786e756d3d6d696e2831302c23656e656d696573290a206c6f63616c206d79696e6465783d666c7228726e64286d61786e756d29290a200a206d79696e6465783d23656e656d6965732d6d79696e6465780a206c6f63616c206d79656e3d656e656d6965735b6d79696e6465785d0a206966206d79656e3d3d6e696c207468656e2072657475726e20656e640a200a206966206d79656e2e6d697373696f6e3d3d2270726f74656322207468656e0a20206d79656e2e6d697373696f6e3d226174746163220a20206d79656e2e616e")
    (hex 19968 "697370642a3d330a20206d79656e2e776169743d36300a20206d79656e2e7368616b653d36300a20656e640a656e640a0a66756e6374696f6e207069636b6669726528290a206c6f63616c206d61786e756d3d6d696e2831302c23656e656d696573290a206c6f63616c206d79696e6465783d666c7228726e64286d61786e756d29290a200a20666f72206d79656e20696e20616c6c28656e656d6965732920646f0a20206966206d79656e2e747970653d3d3420616e64206d79656e2e6d697373696f6e3d3d2270726f74656322207468656e0a202020696620726e6428293c302e35207468656e0a2020202066697265737072656164286d79656e2c3132")
    (hex 20224 "2c312e332c726e642829290a2020202072657475726e0a202020656e640a2020656e640a20656e640a200a206d79696e6465783d23656e656d6965732d6d79696e6465780a206c6f63616c206d79656e3d656e656d6965735b6d79696e6465785d0a206966206d79656e3d3d6e696c207468656e2072657475726e20656e640a200a206966206d79656e2e6d697373696f6e3d3d2270726f74656322207468656e0a20206966206d79656e2e747970653d3d34207468656e0a2020202d2d79656c6c6f77206775790a20202066697265737072656164286d79656e2c31322c312e332c726e642829290a2020656c73656966206d79656e2e747970653d3d3220")
    (hex 20480 "7468656e0a2020202d2d726564206775790a20202061696d656466697265286d79656e2c32290a2020656c73650a20202066697265286d79656e2c302c32290a2020656e640a20656e640a656e640a0a0a66756e6374696f6e206d6f7665286f626a290a206f626a2e782b3d6f626a2e73780a206f626a2e792b3d6f626a2e73790a656e640a0a66756e6374696f6e206b696c6c656e286d79656e290a206966206d79656e2e626f7373207468656e0a20206d79656e2e6d697373696f6e3d22626f737335220a20206d79656e2e7068626567696e3d740a20206d79656e2e67686f73743d747275650a20206562756c733d7b7d0a20206d75736963282d3129")
    (hex 20736 "0a2020736678283531290a202072657475726e0a20656e640a0a2064656c28656e656d6965732c6d79656e292020200a207366782832290a200a0a206578706c6f6465286d79656e2e782b342c6d79656e2e792b34290a206c6f63616c20636865726368616e63653d302e310a206c6f63616c2073636f72656d756c743d310a200a206966206d79656e2e6d697373696f6e3d3d22617474616322207468656e0a202073636f72656d756c743d320a2020696620726e6428293c302e35207468656e0a2020207069636b617474616328290a2020656e640a2020636865726368616e63653d302e320a20656e640a200a2073636f72652b3d6d79656e2e73636f")
    (hex 20992 "72652a73636f72656d756c740a2069662073636f72656d756c74213d31207468656e0a2020706f70666c6f6174286d616b6573636f7265286d79656e2e73636f72652a73636f72656d756c74292c6d79656e2e782b342c6d79656e2e792b34290a20656e640a200a20696620726e6428293c636865726368616e6365207468656e0a202064726f7069636b7570286d79656e2e782c6d79656e2e79290a20656e640a656e640a0a66756e6374696f6e2064726f7069636b7570287069782c706979290a206c6f63616c206d797069636b3d6d616b6573707228290a206d797069636b2e783d7069780a206d797069636b2e793d7069790a206d797069636b2e73")
    (hex 21248 "793d302e37350a206d797069636b2e7370723d34380a20616464287069636b7570732c6d797069636b290a656e640a0a66756e6374696f6e20706c6f676963286d797069636b290a20636865722b3d310a20736d6f6c5f736877617665286d797069636b2e782b342c6d797069636b2e792b342c3134290a20696620636865723e3d3130207468656e0a20202d2d6765742061206c6966650a20206966206c697665733c34207468656e0a2020206c697665732b3d310a202020736678283331290a202020636865723d300a202020706f70666c6f6174282231757021222c6d797069636b2e782b342c6d797069636b2e792b34290a2020656c73650a202020")
    (hex 21504 "2d2d706f696e74730a20202073636f72652b3d35300a202020706f70666c6f6174286d616b6573636f7265283530292c6d797069636b2e782b342c6d797069636b2e792b34290a202020736678283330290a202020636865723d300a2020656e640a20656c73650a2020736678283330290a20656e640a656e640a0a66756e6374696f6e20616e696d617465286d79656e290a206d79656e2e616e696672616d652b3d6d79656e2e616e697370640a20696620666c72286d79656e2e616e696672616d6529203e20236d79656e2e616e69207468656e0a20206d79656e2e616e696672616d653d310a20656e640a206d79656e2e7370723d6d79656e2e616e69")
    (hex 21760 "5b666c72286d79656e2e616e696672616d65295d0a656e640a2d2d3e380a2d2d62756c6c6574730a0a66756e6374696f6e2066697265286d79656e2c616e672c737064290a206c6f63616c206d796562756c3d6d616b6573707228290a206d796562756c2e783d6d79656e2e782b330a206d796562756c2e793d6d79656e2e792b360a200a206966206d79656e2e747970653d3d34207468656e0a20206d796562756c2e783d6d79656e2e782b370a20206d796562756c2e793d6d79656e2e792b31330a20656c73656966206d79656e2e626f7373207468656e0a20206d796562756c2e783d6d79656e2e782b31350a20206d796562756c2e793d6d79656e2e")
    (hex 22016 "792b3233200a20656e640a200a206d796562756c2e7370723d33320a206d796562756c2e616e693d7b33322c33332c33342c33337d0a206d796562756c2e616e697370643d302e350a200a206d796562756c2e73783d73696e28616e67292a7370640a206d796562756c2e73793d636f7328616e67292a7370640a200a206d796562756c2e636f6c773d320a206d796562756c2e636f6c683d320a206d796562756c2e62756c6d6f64653d747275650a200a206966206d79656e2e626f7373213d74727565207468656e0a20206d79656e2e666c6173683d340a2020736678283239290a20656c73650a2020736678283334290a20656e640a200a2061646428")
    (hex 22272 "6562756c732c6d796562756c290a200a2072657475726e206d796562756c0a656e640a0a66756e6374696f6e2066697265737072656164286d79656e2c6e756d2c7370642c62617365290a20696620626173653d3d6e696c207468656e0a2020626173653d300a20656e640a20666f7220693d312c6e756d20646f0a202066697265286d79656e2c312f6e756d2a692b626173652c737064290a20656e640a656e640a0a66756e6374696f6e2061696d656466697265286d79656e2c737064290a206c6f63616c206d796562756c3d66697265286d79656e2c302c737064290a200a206c6f63616c20616e673d6174616e322828736869702e792b34292d6d79")
    (hex 22528 "6562756c2e792c28736869702e782b34292d6d796562756c2e78290a0a206d796562756c2e73783d73696e28616e67292a7370640a206d796562756c2e73793d636f7328616e67292a737064200a656e640a0a66756e6374696f6e2063686572626f6d6228290a206c6f63616c207370633d302e32352f28636865722a32290a200a20666f7220693d302c636865722a3220646f0a20206c6f63616c20616e673d302e3337352b7370632a690a20200a20206c6f63616c206e657762756c3d6d616b6573707228290a20206e657762756c2e783d736869702e780a20206e657762756c2e793d736869702e792d330a20206e657762756c2e7370723d31370a20")
    (hex 22784 "206e657762756c2e646d673d330a20200a20206e657762756c2e73783d73696e28616e67292a340a20206e657762756c2e73793d636f7328616e67292a340a200a20206164642862756c732c6e657762756c290a20656e640a200a206269675f73687761766528736869702e782b332c736869702e792b33290a207368616b653d350a206d757a7a6c653d350a20696e76756c3d33300a20666c6173683d330a20736678283333290a200a656e640a2d2d3e380a2d2d626f73730a0a66756e6374696f6e20626f737331286d79656e290a202d2d206d6f76656d656e740a206c6f63616c207370643d320a200a206966206d79656e2e73783d3d30206f72206d")
    (hex 23040 "79656e2e783e3d3933207468656e0a20206d79656e2e73783d2d7370640a20656e640a206966206d79656e2e783c3d33207468656e0a20206d79656e2e73783d7370640a20656e640a202d2d2073686f6f74696e670a20696620742533303e33207468656e0a20206966207425333d3d30207468656e0a20202066697265286d79656e2c302c32290a2020656e640a20656e640a200a202d2d207472616e736974696f6e0a206966206d79656e2e7068626567696e2b382a33303c74207468656e0a20206d79656e2e6d697373696f6e3d22626f737332220a20206d79656e2e7068626567696e3d740a20206d79656e2e73756270686173653d310a20656e64")
    (hex 23296 "0a206d6f7665286d79656e290a656e640a0a66756e6374696f6e20626f737332286d79656e290a206c6f63616c207370643d312e350a200a202d2d206d6f76656d656e740a206966206d79656e2e73756270686173653d3d31207468656e0a20206d79656e2e73783d2d7370640a20206966206d79656e2e783c3d34207468656e0a2020206d79656e2e73756270686173653d320a2020656e640a20656c73656966206d79656e2e73756270686173653d3d32207468656e0a20206d79656e2e73783d300a20206d79656e2e73793d7370640a20206966206d79656e2e793e3d313030207468656e0a2020206d79656e2e73756270686173653d330a2020656e")
    (hex 23552 "64200a20656c73656966206d79656e2e73756270686173653d3d33207468656e0a20206d79656e2e73783d7370640a20206d79656e2e73793d300a20206966206d79656e2e783e3d3931207468656e0a2020206d79656e2e73756270686173653d340a2020656e6420200a20656c73656966206d79656e2e73756270686173653d3d34207468656e0a20206d79656e2e73783d300a20206d79656e2e73793d2d7370640a20206966206d79656e2e793c3d3235207468656e0a2020202d2d207472616e736974696f6e0a2020206d79656e2e6d697373696f6e3d22626f737333220a2020206d79656e2e7068626567696e3d740a2020206d79656e2e73793d30")
    (hex 23808 "0a2020656e6420200a20656e64200a202d2d2073686f6f74696e670a20696620742531353d3d30207468656e0a202061696d656466697265286d79656e2c737064290a20656e640a0a206d6f7665286d79656e290a656e640a0a66756e6374696f6e20626f737333286d79656e290a202d2d206d6f76656d656e740a206c6f63616c207370643d302e350a200a206966206d79656e2e73783d3d30206f72206d79656e2e783e3d3933207468656e0a20206d79656e2e73783d2d7370640a20656e640a206966206d79656e2e783c3d33207468656e0a20206d79656e2e73783d7370640a20656e640a0a202d2d2073686f6f74696e670a20696620742531303d")
    (hex 24064 "3d30207468656e0a202066697265737072656164286d79656e2c382c322c74696d6528292f32290a20656e64200a200a202d2d207472616e736974696f6e0a206966206d79656e2e7068626567696e2b382a33303c74207468656e0a20206d79656e2e6d697373696f6e3d22626f737334220a20206d79656e2e73756270686173653d310a20206d79656e2e7068626567696e3d740a20656e640a206d6f7665286d79656e290a656e640a0a66756e6374696f6e20626f737334286d79656e290a206c6f63616c207370643d312e350a200a202d2d206d6f76656d656e740a206966206d79656e2e73756270686173653d3d31207468656e0a20206d79656e2e")
    (hex 24320 "73783d7370640a20206966206d79656e2e783e3d3931207468656e0a2020206d79656e2e73756270686173653d320a2020656e640a20656c73656966206d79656e2e73756270686173653d3d32207468656e0a20206d79656e2e73783d300a20206d79656e2e73793d7370640a20206966206d79656e2e793e3d313030207468656e0a2020206d79656e2e73756270686173653d330a2020656e64200a20656c73656966206d79656e2e73756270686173653d3d33207468656e0a20206d79656e2e73783d2d7370640a20206d79656e2e73793d300a20206966206d79656e2e783c3d34207468656e0a2020206d79656e2e73756270686173653d340a202065")
    (hex 24576 "6e6420200a20656c73656966206d79656e2e73756270686173653d3d34207468656e0a20206d79656e2e73783d300a20206d79656e2e73793d2d7370640a20206966206d79656e2e793c3d3235207468656e0a2020202d2d207472616e736974696f6e0a2020206d79656e2e6d697373696f6e3d22626f737331220a2020206d79656e2e7068626567696e3d740a2020206d79656e2e73793d300a2020656e6420200a20656e64200a0a202d2d2073686f6f74696e670a20696620742531323d3d30207468656e0a20206966206d79656e2e73756270686173653d3d31207468656e0a20202066697265286d79656e2c302c32290a2020656c73656966206d79")
    (hex 24832 "656e2e73756270686173653d3d32207468656e0a20202066697265286d79656e2c302e32352c32290a2020656c73656966206d79656e2e73756270686173653d3d33207468656e0a20202066697265286d79656e2c302e352c32290a2020656c73656966206d79656e2e73756270686173653d3d34207468656e0a20202066697265286d79656e2c302e37352c32290a2020656e640a20656e640a202d2d207472616e736974696f6e0a206d6f7665286d79656e290a656e640a0a66756e6374696f6e20626f737335286d79656e290a206d79656e2e7368616b653d31300a206d79656e2e666c6173683d3130200a200a206966207425383d3d30207468656e")
    (hex 25088 "0a20206578706c6f6465286d79656e2e782b726e64283332292c6d79656e2e792b726e6428323429290a20207366782832290a20207368616b653d320a20656e640a0a206966206d79656e2e7068626567696e2b332a33303c74207468656e0a09206966207425343d3d32207468656e0a0920206578706c6f6465286d79656e2e782b726e64283332292c6d79656e2e792b726e6428323429290a0920207366782832290a2020207368616b653d320a0920656e640a20656e640a0a206966206d79656e2e7068626567696e2b362a33303c74207468656e0a2020666c6173683d330a202073636f72652b3d3130300a2020706f70666c6f6174286d616b6573")
    (hex 25344 "636f726528313030292c6d79656e2e782b31362c6d79656e2e792b36290a20206269676578706c6f6465286d79656e2e782b31362c6d79656e2e792b3132290a20207368616b653d31350a2020656e656d6965733d7b7d0a2020736678283335290a20656e640a656e640a5f5f6766785f5f0a30303030303030303030303232303030303030323230303030303032323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636363636363363636636363633737373737363663366363636363636363636363636363300a303030303030303030303238")
    (hex 25600 "38323030303032383832303030303238383230303030303030303030303030373730303030303037373030303030303737303030303063373763303030303037373030306363636363636363636363636363636363373737636363633737373737373663373736636363636363636363636363300a30303730303730303030323838323030303032383832303030303238383230303030303030303030303063373763303030303037373030303030633737633030306363636363633030306337376330306363636363636363373763636363636336373737366363636363633637376363633737636337373763636363636363300a30303037373030303030")
    (hex 25856 "323838653230303265383865323030326538383230303030303030303030303063636363303030303063633030303030636363633030303063636363303030306363636330306363636336636363373763636363636337373737376363636363633737366363633637373737373663633663636363300a30303037373030303032376338383230326538376338653230323838376332303030303030303030303030636330303030303063633030303030306363303030303030303030303030303063633030306363633637636363373763636363636337376337376363636363363737636363636337373737366363633736636363300a3030373030373030")
    (hex 26112 "3032313138383230323838313138383230323838313132303030303030303030303030303030303030303063633030303030303030303030303030303030303030303030303030306363633737636363373763636363633737366337373663636363373736636363636363373736636363633737636363300a30303030303030303032353538323230303238353538323030323238353532303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363633737636363373763636363633737363637373763636336373763636363636363373763636363633737636363300a303030303030")
    (hex 26368 "30303030323939323030303032393932303030303239393230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363633737636363373763636363363737373737373763636337373663636363636363373763636363633737636363300a30393939393030303030393939393030303030303030303030303030303030303030303030303030303333303033333030333330303333303033333030333330303333303033333030303030303030306363633737636363373736363663373737363636373736633737373737373763636363373736636363633737636363300a39393737")
    (hex 26624 "393930303039616161613930303030303030303030303030303030303030303030303030333362333362333333336233336233333333623333623333333362333362333330303030303030306363633737636363373737373736373763636363363736633737373737373763636363373736636363633737636363300a39613737613930303961613737616139303030303030303030303030303030303030303030303030336262626262623333626262626262333362626262626233336262626262623330303030303030306363633737636363373636363636366363636363636363636363636363636363636363363663636363633737636363300a3961")
    (hex 26880 "3737613930303961373737376139303030303030303030303030303030303030303030303030336237373137623333623737313762333362373731376233336237373137623330303030303030306363633737636363636363636363636363636363636363636363636363636363636363636363636363633737636363300a39613737613930303961373737376139303030303030303030303030303030303030303030303030306237313137623030623731313762303062373131376230306237313137623030303030303030306363633737636363636363636363636363363636373763633737636363633636366363363636636363633737636363300a")
    (hex 27136 "39396161393930303961613737616139303030303030303030303030303030303030303030303030303033373733303030303337373330303030333737333030303033373733303030303030303030306363633737636363373737373737636363373737373763633737366363633737366337373737376363633737636363300a30396161393030303039616161613930303030303030303030303030303030303030303030303030303330333330333030333033333033303033303333303330303330333330333030303030303030306363633737636363373737373737376363363736636363633637376363363737636337373636376363633737636363")
    (hex 27392 "300a30303939303030303030393939393030303030303030303030303030303030303030303030303030303330303030333033303030303030333033303030303330303333303033333030303030303030306363633637366363373763636337373763363736636363636337376363373736633637376363636363633737636363300a3030656530303030303065653030303030303737303030303030303030303030303030303030303030383830303838303038383030383830303030303030303030303030303030303030303030303030636363363736636337373663633637376336373737376363633737636337376363363737373663636336373663")
    (hex 27648 "6363300a30653232653030303065383865303030303763633730303030303030303030303030303030303030383838383838383838303038383030383030303030303030303030303030303030303030303030306363633637366363373736636363373763363737373763636336373636373663636336373737376363363736636363300a653265383265303065383765386530303763373763373030303030303030303030303030303030303838383838383838383030303030303830303030303030303030303030303030303030303030303063636336373763633637366363363737633637366363636363633737373763636363636336373763633637")
    (hex 27904 "36636363300a65323838326530306538656538653030376337376337303030303030303030303030303030303030383838383838383838303030303030383030303030303030303030303030303030303030303030306363636337376363363736633637373663363737636363636363373737376363636363636337376363373763636363300a30653232653030303065383865303030303763633730303030303030303030303030303030303030303838383838383030383030303038303030303030303030303030303030303030303030303030306363636337376363363737373737376363363737373736636363363737636363633737363737376363")
    (hex 28160 "373763636363300a30306565303030303030656530303030303037373030303030303030303030303030303030303030303038383838303030303830303830303030303030303030303030303030303030303030303030306363636337373663633737373736636363363636363663636363633736636363633637373737636363373763636363300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383030303030303838303030303030303030303030303030303030303030303030303030636363636363636363636363636363636363636363636363636363636363636363636363636363")
    (hex 28416 "6363636363636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636336363636363636363636363636363636363636363663636363636363636363636363300a303030626262623030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303036363636363737373737373737373737373737373737373737373737373737373737373737")
    (hex 28672 "37373737373736363636300a30303062306262303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303737373737373737373737373636363737363637373636633637373663633737363737363737373737373737373737300a30306230306230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306337373737373663363737366363633737636336376363636363376363633736633637")
    (hex 28928 "636337636337636337373736300a30306230303838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306337373737376363633737636337373736636363373663373663366363363763633636636337366363633637373763300a3038383038373838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633637373737633663363763373737376363366337366337376336636363376363")
    (hex 29184 "6363636337376363363737373663300a38373838303838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363373737376363636337636336363763636363363663366363376363363663376363366336373663373737376363300a383838383038383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063636337376363633663363763636336633637366336636363373763636336")
    (hex 29440 "63376336376336376363373737636363300a30383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363633637633637373636373736373737373737373737373737373737373737373737373637373636373736636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636337373737373737373737373737373737373737373737373737")
    (hex 29696 "373737373737373737373737373763636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363373737363636363663636363636363636363636363636363636363636336363636363737376363636363300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030636363636363636363636363636363636363636363636363636363")
    (hex 29952 "6363636363636363636363636363636363636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636363373737376363636363636363636363373737376363636363636363636363636363300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063636363636363636363636363636336373737366363636363")
    (hex 30208 "63633637373736636363636363636363636363636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636363636363363737373736636336373737366363636363636363636363636363636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636363636363636336373737")
    (hex 30464 "373737373663636363636363636363636363636363636363300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306363636363636363636363636363636363636363633637373736636363636363636363636363636363636363636363300a3030303030656530303030306262626262626262303030303065653030303030303030303065653030303030626262626262626230303030306565303030303030303030306565303030303062626262626262623030303030656530303030303030303030")
    (hex 30720 "6565303030303062626262626262623030303030656530303030300a65653030303865376531626262626261616262626262316537653830303065656565303030386537653162626262626161626262626231653765383030306565656530303038653765316262626262616162626262623165376538303030656565653030303865376531626262626261616262626262316537653830303065650a653765303133383837336262626161373761616262623337383833313065376565376530313338383733626262616137376161626262333738383331306537656537653031333838373362626261613737616162626233373838333130653765653765")
    (hex 30976 "30313338383733626262616137376161626262333738383331306537650a38653738336233333362626162616137376161626162623333336233383765383865373833623333336262616261613737616162616262333333623338376538386537383362333333626261626161373761616261626233333362333837653838653738336233333362626162616137376161626162623333336233383765380a30386538313362626262626262626137376162626262626262623331386538303038653831336262626262626262626161626262626262626262333138653830303865383133626262626262626262616162626262626262626233313865383030")
    (hex 31232 "386538313362626262626262626261616262626262626262623331386538300a30383838313162626262626262626261616262626262626262623131383838303038383831313333623333626262626262626262623333623333313138383830303838383131333362333362626262626262626262333362333331313838383030383838313133336233336262626262626262626233336233333131383838300a3030313131333362626262623333626262623333626262626233333131313030303031313362313162626233333333333333333333626262313162333131303030303131336231316262623333333333333333333362626231316233313130")
    (hex 31488 "3030303131336231316262623333333333333333333362626231316233313130300a30306262313133626261626262333362623333626262616262333131626230303030626231336262313362626233333333333362626233316262333162623030303062623133626231336262623333333333336262623331626233316262303030306262313362623133626262333333333333626262333162623331626230300a626233333331313362626162626262626262626262616262333131333333626262623333333133333333333362626137376162623333333333333133333362626262333333313333333333336262613737616262333333333333313333")
    (hex 31744 "33626262623333333133333333333362626137376162623333333333333133333362620a62626262333133333362626161376262626237616162623333333133626262626237373133656536363333333333626262623333333333363665653331373762623737313365653636333333333362626262333333333336366565333137376262373731336565363633333333336262626233333333333636656533313737620a33623333333331333333336262623737373762626233333333313333333362333337313133656566666636363333333333333333363666666665653331313733333731313365656666663636333333333333333336366666666565")
    (hex 32000 "333131373333373131336565666666363633333333333333333636666666656533313137330a63333333333333626233333333336262626233333333336262333333333333636333373733656666663737663137373131313131663737666666653337373363633337373365666666373766313737313131313166373766666665333737336363333737336566666637376631373731313131316637376666666533373733630a3063336262336233626262333333333333333333336262623362336262336330306333623365666637373737313737313163373137373737666665336233633030633362336566663737373731373731316337313737373766")
    (hex 32256 "6665336233633030633362336566663737373731373731316337313737373766666533623363300a30306331626233623333626262623333333362626262333362336262316330303030633162336566373737373731316363373137373737376665336231633030303063316233656637373737373131636337313737373737666533623163303030306331623365663737373737313163633731373737373766653362316330300a303030313362623362623333336262626262623333336262336262333130303030303031336233656666373737373131313137373737666665336233313030303030303133623365666637373737313131313737373766")
    (hex 32512 "66653362333130303030303031336233656666373737373131313137373737666665336233313030300a30333331633362623333616161333333333333616161333362623363313333303033333163336233656566373737373737373737376665653362336331333330303033316333623365656637373737373737373737666565336233633133303030303331633362336565663737373737373737373766656533623363313330300a33626233316333626262333333613737373761333333626262336331336262333362623331633362333365656537373737373765656533336233633133626233303362333163336233336565653737373737376565")
    (hex 32768 "653333623363313362333030303362316333623333656565373737373737656565333362336331623330300a33636363313363336262626262333333333333626262626233633331636363333363636331336333626233333365656565656533333362623363333163636333336263633133633362623333336565656565653333336262336333313363623330336263313363336262333333656565656565333333626233633331636233300a3030303033623363333362626262613737616262626233336333623330303030303030303362336333336262623333333333336262623333633362333030303033633030336233633333626262333333333333")
    (hex 33024 "6262623333633362333030636330336330333333633333626262333333333333626262333363333333306333300a30303033623363636333333362626262626262623333336363633362333030303030303362336363633333336262613737616262333333636363336233303030303030303362336363333333626261373761626233333363633362333030303030303030336233636333333362626137376162623333336363336233303030300a303030333363303033626333336262626262623333636233303063333330303030303033336330303362633333626262626262333363623330306333333030303030303033336330336263333362626262")
    (hex 33280 "62623333636233306333333030303030303030336263303362633333626262626262333363623330636233303030300a30303033633030303362336333636232326263336333623330303063333030303030303363303030336233633363623232626333633362333030306333303030303030303363303033623363336362323262633363336233303063333030303030303030303363306333626333636232326263336362336330633330303030300a30303030303030303333633063633231313263633063333330303030303030303030303030303030333363306363323131326363306333333030303030303030303030303030303063333330636332")
    (hex 33536 "313132636330333363303030303030303030303030303030303063333063633231313263633033633030303030303030300a30303030303030306363303030306333336330303030636330303030303030303030303030303030636330303030633333633030303063633030303030303030303030303030303030636330303063333363303030636330303030303030303030303030303030303030636330306333336330306363303030303030303030300a3030303030303030303030303030303030303030303030303030303730303030303230303030323030323030303032303032303030303230303230303030323035353535353535353535353535")
    (hex 33792 "3535353535353535353535353535353535353530323232323232303032323232323230303232323232323030323232323232300a30303062623030303030306262303030303030373730303030303037373030303032326666323230303232666632323030323266663232303032326666323230303537383837353030353738383735306435363234363564303537383837353032326536366532323232653636653232323265363665323232326536366532320a303036363636303030303636363630303630363636363036363036363636303630326666666632303032666666663230303266666666323030326666666632303035363234363530643536")
    (hex 34048 "32343635643035313737313530643536323436356432373736313737323237373631373732323737363137373232373731363737320a30353636363635303635363636363536623536363636356262353636363635623030373764373030303037376437303030303764373730303030373764373030643531373731356430353137373135303035363638363530303531373731353032363161613137323231366161313632323631616136313232363161613136320a36353633373635366235363337363562303536333736353030353633373635303038353737353830303835373735383030383537373538303038353737353830303536363836353030")
    (hex 34304 "353636383635303035643234643530303536363836353032656539396565323265653939656532326565393965653232656539396565320a62303633333630623030363333363030303036333336303030303633333630303038303535303830303830353530383030383035353038303038303535303830356435323435643530356432346435303035303535303530303564323464353032323239393232323232393939393232323232393932323232323239393232320a3030363333363030303036333336303030303633333630303030363333363030306330303030633030376330303763303037633030633730303763303037633035303035353030")
    (hex 34560 "3530353035353035303035303030303530303530353530353032303939393930323032303030303230323039393939303230323939393932300a30303036363030303030303636303030303030363630303030303036363030303030633763373030303030376330303030303737636330303030303763303030646430303030646430646430306464303035646464643530306464303064643032323030303032323032323030323230323230303030323230323230303232300a303066663838303030306666383830303030303030303030303030303030303032303030303030323032303030303230303030303030303030303030303030303333353030")
    (hex 34816 "35333330333530303533303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30383838383838303038383838383830303030303030303030303030303030303232303030303232323230303030323230303030303030303030303030303030333330646430333330333064643033303030353030353030303335303035333030303030303030303030303030303030303030303030303030303030303030300a30363535353536303037363636353530303030303030303030303030303030303232323232323232323232323232323230303030303030303030303030303030336238")
    (hex 35072 "646438623333333864643833333033306464303330303330646430333030336533336533303065333365333330303333653333333030336533333365300a36353636363635353736353535353635303030303030303030303030303030303238323232323832323832323232383230303030303030303030303030303030303332646432333030623264643262303033386464383330333338646438333365333365333365333333653333653333336533336533333365333365333333650a3537363535353736353535373736353530303030303030303030303030303030323838383838383232383838383838323030303030303030303030303030303033")
    (hex 35328 "6233353533623333623335353362333033336464333330306232646432623033333330303333333333333030333333333333303033333333333330303333330a30363535373636303035373635353530303030303030303030303030303030303238373838373832323837383837383230303030303030303030303030303030333333646433333333333364643333333033623535623330336233353533623365336533333333626265333333333365626533653333336265336533333333620a303035373635303030303635353730303030303030303030303030303030303032383838383838323038303030303830303030303030303030303030303030")
    (hex 35584 "30333330353530333330333035353033303033626464623330333333646433333334626262626562343462626265626234346262626265623434626262656265340a30303036353030303030303537303030303030303030303030303030303030303038303030303830303030303030303030303030303030303030303030303030303030303030303030303030303030303030333535333030303330353530333030343434343434303034343434343430303434343434343030343434343434300a30303636363030303030363636303030303036363630303030303638363030303030383838303030303032323232303030303232323230303030323232")
    (hex 35840 "323030303032323232303030636363636363303063303030306330303030303030303030303030303030303030303030303030303030303030303030303030303030300a30353535353630303035353535363030303535383536303030353838383630303038383238383030303265656565323030326565656532303032656565653230303265656565323063306330633063636330303030303063303030303030303030303030303030303030303030303030303030303030303030303030303030300a3535353535353630353535383535363035353838383536303538383238383630383832323238383032656537376565323265653737656532326565")
    (hex 36096 "6565656532326565373765653263303232323230636363326332633063633032323232306330303232323230303030303030303030303030303030303030303030303030300a35353535353535303535383838353530353838323838353038383232323838303832323232323830326565373765653232656537376565323265653737656532326565373765653263633263616330636330326161323063633063616332636363303261613230633030303030303030303030303030303030303030303030300a313535353535353031353538353535303135383838353530313838323838353038383232323838303265656565656532326565656565653232")
    (hex 36352 "65656565656532326565656565653263303261613230636330636163326363633032616132306363633263616330633030303030303030303030303030303030303030303030300a30313535353530303031353535353030303135383535303030313838383530303038383238383030323232323232323232323232323232323232323232323232323232323232323230303232323230306330323232323063636332633263306363303232323230633030303030303030303030303030303030303030303030300a30303131313030303030313131303030303031313130303030303138313030303030383838303030323032303230323030323032303230")
    (hex 36608 "323230323032303230303230323032303230303030303030303030303030303030633030303030306363306330633063633030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030323030303230303030323030303230303030323030303230303030323030303230303030303030303030303030303030306330303030633030636363636363303030303030303030303030303030303030303030303030300a3030303838303030303030393930303030303038393030303030303839303030303030303030303030313131313131303031313131")
    (hex 36864 "3131303030303030303030303064383964303030303138393130303030313839313030303031393831303030303030353530303030303035303030303030353030303030303535303030300a37303636363630353037363636363530303036373636303030303636353630303030303030303030303163636363313030316363636331303030303030303030306435313135643030306435313530303030313131313030303035313564303030303035353030303030303535303030303030353530303030303035353030300a313636316336363130313631363631303030363636363030303031363636303030303030303030303031636363633130303163")
    (hex 37120 "63636331303030303030303030643531616131356430313531613131303030313535313030303131613135313030353535353535303035353535353530303535353535353030353535353535300a37303636363630353037363636363530303036373636303030303636353630303030303030303030303137636337313030313763633731303030303030303030643531616131356430643531613135303030643535643030303531613135643032323232323232323232323232323232323232323232323232323232323232320a30303736363530303030373636353030303037363635303030303736363530303030303030303030303137636337313030")
    (hex 37376 "313763633731303030303030303030366435303035643630363530303564303030366464363030306435303035363032363036303630323236303630363032323636363636363232363036303630320a30303037353030303030303735303030303030373530303030303037353030303030303030303030303131313131313030313131313131303030303030303030363664303064363030303664306436303030363636363030303664306436303032303030303030323230363036303632323232323232323032303630363036320a3030303735303030303030373530303030303037353030303030303735303030303030303030303031313030303031")
    (hex 37632 "3130313130303131303030303030303030303736303036373030303636303630303030303636303030303036303636303032303630363036323232323232323230303030303030303032323232323232300a30303036303030303030303630303030303030363030303030303036303030303030303030303030313130303030313130313130303131303030303030303030303037303037303030303037303730303030303737303030303037303730303032323232323232303030303030303030303030303030303030303030303030300a303030373033333030303730303030303030376433333030303333333033333330303030303030303030323232")
    (hex 37888 "32303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303064333330303030306433333030303032383833333030336262336262333030303030303030303838383838323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30373738383237303030323838333330303731666664313030303838343230303030323838323030303838")
    (hex 38144 "383838323030303238383230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30373166666431303037376666643730303737383832373030386565386538303033333365333333303865653865383030383865653838333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030323838323030303731383832313030303238383230303038656538653830303362623462623330")
    (hex 38400 "3865653865383030386565656538333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30376438383264303030323838323030303764383832643030383838383832303038656565653830303038383432303030386565656538303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303032383832303030376438383264303030646666643030303838383838323030383865653838")
    (hex 38656 "30303362623362623330383865653838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30306466666430303030646666643030303030303030303030303232323230303030323838323030303333333033333330303238383230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303037")
    (hex 38912 "373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373730303030300a30303030303030303030303030303030303030303030303030303030303030303030373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373030300a3030303031343961613934313030303030303030303132323232313030303030303737")
    (hex 39168 "3737383838383737383837373737383837383838383838373838383838373737373838383838373738383737373738383737373737383838383837373737373738383838373737373838373737373738383738383838383737373730300a30303031393737376161393231303030303030303239616161613932303030303037373838383838383837383837373737383837383838383838373838383838383737373838383838383737383837373838373737373737383838383838373737383838383838383837373838383737373838383738383838383837373730300a306430396137376139343939323064303064303439373737376161393230643037")
    (hex 39424 "37373838653737383837383837373737383837383837373737373838373738383837373838373738383837383837373838373737373737383837373838373737383837373838383837373838383737373838383738383737383837373737300a30363139616161393432323434313630303631396137373934343239343136303737383865373737373737383837373737383837383837373737373838373737383837373838373737383837373838383837373737373737383837373838373738383737373838383838373838383837383838383738383737383837373737300a30373134396139323232343934313730303631343961393434323234343136")
    (hex 39680 "303737383837373737373737383838383838383837383838383838373838373738383837373838373738383837373838383837373737373737383838383837373738383737383838383838373838383837383838383738383838383737373737300a30376432343961616139393432643730303664323439616139393434326436303737383837373737373737383838383838383837383838383838373838383838383737373838383838383737373738383737373737373737383838383838373738383838383838383838373838373838383738383738383838383837373737300a3036376432323434343432326437363030373764323232343432323264")
    (hex 39936 "3737303737383865373737373737383837373737383837383837373737373838383838373737373838383838373737373738383737373737373737383837376538383738383838383838383838373838373838383738383738383737653838373737300a30643636363232343432323636366430306437373632343939343236373764303737373838653737383837383837373737383837383837373737373838373838383737373838373838383737373738383737373737373737383837373738383737383838383838383837373838373738373738383738383737373838373737300a303636643531343939343135643636303031643135323937343932")
    (hex 40192 "35316431303037373838383838383837383837373737383837383838383838373838373738383837373838373738383837373738383737373737373737383838383838383737383838383838383837373838373738373738383738383838383838373730300a30303431353139373439313531343030303636313531393434613135313636303037373737383838383737383837373737383837383838383838373838373737383838373838373737383838373738383737373737373737383838383865373737373738383838373737373838373737373738383738383838386537373730300a30306130303139343461313030613030303034303031343961")
    (hex 40448 "343130303430303030373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373030300a30303030303034396134303030393030303061303030303030303030306130303030303037373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373730303030300a3030303030303030303030303030303030303030303030")
    (hex 40704 "3030303030303930303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6c6162656c5f5f0a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030643030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303130300a3030303030303030303030")
    (hex 40960 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303032313230303030303030303030303030303130303030303030303032323130323030303032303030303030303030323230303030303032323231323030303030303030303030303232303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030")
    (hex 41216 "30303030303030303030303030303032303030303030303030303030303232303030303030303032323230303030303032303030303030303030323232303030303032323232303030303030303030303030303230303030303230303030303030303030303030303030306430303030303030303030300a30303030303030303030303030303030303030303030303030303030303036303030303030303232303030303030303031323230303230303030303030303030303030323032323030303032313230303030303030303230303032323030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030")
    (hex 41472 "303030303030303030303030303030303030303030303030303030303030303032303030303030303032323230323230303030323030303030303032323232303030303030303030303030303030303030323232303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030323030303032303030303030303032323230303030303032323030303030303232323232303030303030303230303030303030303030323232323030303030303030303030303230303030303030303030303030303030303030303030300a3030303030")
    (hex 41728 "3030303030303030303030303030303030303030303030303030303030303030303032303030303030303030323232303030303232303030303030303232323232303030303030353030303030303030323032323232303030303030303030303030323030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303032303030303030303031323030313032323230303230303030303232323232303030303030323030303030303032306432323230303030303030303030303030323030303030303030303030303030303030303030303030300a303030")
    (hex 41984 "30303030303030303030303030303030303030303030303030303030303030303030303030323030303030303032323230323232323230303232303032323232323230303030303030303030303030303232303232323030303032303030303030303232303030303030323030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030323030303030303030323230323232323230303232323232323232323230303030303030303030303030303230303232323030303030303030303030323230303030303032323030303030303030303030303030303030300a30")
    (hex 42240 "303030303030303030303030303030303630303030303030303030303030303030303030303030323230303030303030323232323232323230303232323232323232323230303030303232303030303030303230323230303030303030303030323032323030303030323232323030303030303030303030303030303030300a3030303030303030303030303030303030303036303030303030303030303030303030303030303030323030303030303032323232323232323232323232323232323232303030303032323030303030303032303030303030303030303030303230323232303030323232323232303030303030303030303030303030303030")
    (hex 42496 "0a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303232323232323232323232323232323232303030303230323230303030303030323030303030303032303030303232323232323232323232323232323030303030303030303030303030303030300a303030303030303030303630303030303030303030303030303030303030303030303230303030303030303030303030303032323232323232323232323232323232303030303030323230303030323030323230323030303032303030303232323232323232323232323232323230303030303030303030303030303030")
    (hex 42752 "30300a30303030303030303030303030303030303030303030323030303030323030303030303030303030303030303030323030303030303232323232323232323232323032323030323232323030303032303232303030303030323030303032323232323232323232323232323232303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 43008 "303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 43264 "3030303030300a30303030303030303030303030303030303030303037373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373730303030303030303030303030303030303030300a303030303030303030303030303030303030303737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373730303030303030303030")
    (hex 43520 "30303030303030300a30303030303030303030303030303030303037373737383838383737383837373737383837383838383838373838383838373737373838383838373738383737373738383737373737383838383837373737373738383838373737373838373737373738383738383838383737373730303030303030303030303030303030300a30303030303030303030303030303030303037373838383838383837383837373737383837383838383838373838383838383737373838383838383737383837373838373737373737383838383838373737383838383838383837373838383737373838383738383838383837373730303030303030")
    (hex 43776 "303030303030303030300a30303030303030303030303030303030303737373838653737383837383837373737383837383837373737373838373738383837373838373738383837383837373838373737373737383837373838373737383837373838383837373838383737373838383738383737383837373737303030303064303030303030303030300a3030303030303030303030303030303030373738386537373737373738383737373738383738383737373737383837373738383737383837373738383737383838383737373737373738383737383837373838373737383838383837383838383738383838373838373738383737373730303030")
    (hex 44032 "3030303064303030303030300a30303030303030303030303030303030303737383837373737373737383838383838383837383838383838373838373738383837373838373738383837373838383837373737373737383838383837373738383737383838383838373838383837383838383738383838383737373737303030303030303030303030303030300a303030303030303030303030303030303037373838373737373737373838383838383838373838383838383738383838383837373738383838383837373737383837373737373737373838383838383737383838383838383838383738383738383837383837383838383838373737373030")
    (hex 44288 "30303030303030303030303030300a30303030303030303030303032303030303737383865373737373737383837373737383837383837373737373838383838373737373838383838373737373738383737373737373737383837376538383738383838383838383838373838373838383738383738383737653838373737303030303032303030303030303030300a30303030303030303030303030303030303737373838653737383837383837373737383837383837373737373838373838383737373838373838383737373738383737373737373737383837373738383737383838383838383837373838373738373738383738383737373838373737")
    (hex 44544 "303030303032303030303030303030300a30303030303030303030303030323030303037373838383838383837383837373737383837383838383838373838373738383837373838373738383837373738383737373737373737383838383838383737383838383838383837373838373738373738383738383838383838373730303030303232303030303030303030300a3030303030303030303030303032303030303737373738383838373738383737373738383738383838383837383837373738383837383837373738383837373838373737373737373738383838386537373737373838383837373737383837373737373838373838383838653737")
    (hex 44800 "3730303030323232303030303030303030300a30303030303030303030303030303030303030373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373030303032323532323030303030303030300a303030303030303030303030313031303030303030373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737")
    (hex 45056 "30303030303031323132313230303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303232323232323230303031303030300a30303030303030303030303030303030303130303030303030303030303636303630363030363630363636303636363030303030303636303630363036303630363636303630363036363630303030303036363036303630363636303630363036363630303030303030")
    (hex 45312 "303030303030323231323132313230303030303030300a30303030303030303030303030303030303230303030303030303030363030303630363036303630363036303036303030303030363030303630363036303630363036303630363036303030303030303630303036303630363636303630363036303630303030303030303030303032323232323232323230303030303030300a3030303030303030303030303030303030303030303030303030303036363630363636303630363036363030303630303030303036363630363636303630363036363630363036303636303030303030363636303636363036303630363036303636363030303130")
    (hex 45568 "3030303030303132313231323132313230303030303030300a30303030303030303030303030303030303030303030303030303030303036303630363036303630363036303036303030303030303036303630363036363630363036303636363036303030303030303030363036303630363036303630363036303030303032323030303232313232323132323231323230303030303030300a303030303030303030303030303030303030303030303030303030303636303036303630363630303630363030363030303030303636303036303630363636303630363030363030363636303030303036363030363036303630363030363630363030303030")
    (hex 45824 "31323030313231323132313231323132303030303030303030300a30303033303330303030303330333030303030323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303032323232323232323230303232323230303030303030303030360a30303362626230303030336262623030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 46080 "303031323032313231323030303231323130303030303030303030300a30333037316230303030303731623030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303032303231323232313030303132323030303030303030303030300a6262303033333362333330303333303030303030303230323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 46336 "3030303030323032313231323130313231303030303030303030303030300a31623030303033373162303030303030303030303032303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030313032323132323231323232303030303030303030303030300a333330303030303337303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 46592 "30303030303030303130313231323132313231323030303030303030303030300a30303130303030303033303030313230303032313030303030303030623030306230303062303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303231323132313231323132313030303036303033333030330a30303030303030303030623030326230303062303130303030306230303062303030623030306230303030303030303030303131303030303030303030303030303030303030303030303030303030303030313130303030303030303030")
    (hex 46848 "303030303030303030303032313231323132313030303030303064303333623333620a30303030303030306230303062303030623032306230303030303030303030303030303030303030303030313131303030303030303130303030303030303030303030303030303030303030303031303130303030303030303030303030303030303030303030303031323132313231303030303030323030303362626262620a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030313131313030303030303030303030303030313131303030303030303030313030303030")
    (hex 47104 "3030303030303030303036303030333233323130303033303330303230303362373731370a30303030303030303030323130303230303132303030303030303030313131313131313131313131313130303030303130303030303030303030303031313131313131313131313131313030303030303030303130313030303031313131313131313131313030303033626262313231303362626230303130303062373131370a303030303030313230333332313333303132313230303030303030313131313131313131313131313131313030303031303131313131303030303030303030303030303030303030303030303030313030313030303030303031")
    (hex 47360 "31313131313131313131313133303330373162323132313237316230313230303030333737330a30303030303132313333623333623333323132303231323030303031313131313131313131313131313131313130303030303030303031313131313130303030303030303030303030303131313130303030303030303031313131313131313131313131313362626230303333336233333030333330323130303033303333300a30303030303031323362626262626233313131323131313030303031313131323232323235353131313131313131313030303030303030303030303031313131313131313131313131313030303030303030303031313131")
    (hex 47616 "313131353532653232323131313137316230303231333731623130303030313230303033303030300a30303030303030313362373731376233323132313230303030303031313132323232323232353535353131313131313131303030303030303030303030303030303030303030303030303030303030303131313131313131313135353665656537373231313130333330303132303337323130303031323030303030303030300a3030303030303030316237313137623131323130313030303030303131313237323732323636363635353531313131313131313131313131303030303030303030303030303030303030303030303131313131313131")
    (hex 47872 "3135353536363665653232653231313130303030303031303031333030313132313030623030306230300a30333330303333303231333737333231323132313230303030303031313132323265656536363636363635353535313131313131313131313131313131313131313131313131313131313131313131313135353535353535363636363632323265653231313130303030303132303030303032313030306230303062303030620a333362333362623331336233333133313131313131303030303030313131323232326566666666666636363636353535353535313131313131313131313131313131313131313131313131313135353535353536")
    (hex 48128 "36363636363666666666323265653231313130303030303031313031303130303030303030303030303030300a62626262626262336233323162313331323132313230303030303031313132653232666666666666666666663636363535353535353531313131313131313131313131313131313131313535353535363636363666666666666666666666666565653231313130303030303032303231323130303030303030303030303030300a33623737313762333132313131323131313231313133303330303031313332336566666666666666666666666666363636363635353535353535353535353535353535353535353535353535353636363636")
    (hex 48384 "366666666666666666666666666565656531313130303030303062323131623030306230303030303030303030300a30623731313762313231323132313231323132313362626230303031336262626566666666666666663737666666666666363636313131373737373731313131313131313131313131313131313636366666666637373766376637666666666665656531313130303030623030316231323062303030623030303030303030300a3030333737333131313131313131313130333033303731623030303131373162656666666666666666663737376637666666666631313137373737373131313131313131636363313131313131366666")
    (hex 48640 "6666663737373737373737376666666665656531313130303030303030313131313030303030303030303030303030300a30333033333033313231323030313230336262623030333333623333313133336566666666666666373737373737373737666666313131373737373737313131313131313163636331313131316666666637373737373737373737376666666665656531313130303030303030303231323030313230303030303030303030300a303330303031333131313130303031303037316230303030333731623131656565666666666666373737373737373737663737373131313737373737373131313131313163636363373731313737")
    (hex 48896 "37373737373737373737373737376666666665656531313130303030303030313131313133313330303030303330333030300a30303031323132313231323130303231323033333030303030333730313131656565666666666637373737373737373737373737373131313737373731313131313131313163633737373131373737373737373737373737373737666666666665656531313130303030303032313231323362626230303030336262623030300a30303131313131313131313130313131313031303030303030303033313131656565666666336666663337373733373737373737373131313737373731313131313131636363373737313131")
    (hex 49152 "373737373737373737373737373737666666666565656531313130303030303031313331333037316230303030303731623030300a30303231313132313031323030313030313132303030303030303030313131316565653366666633373737333737373337373737373731313131313131633163316363636337373731313131373737373737373737373737376637666666656565653131313032303030303030336262623030333333623333303033333030300a3030313131313131303131313030313131313130303030303030303030313131656565666666666666373737373737373737373737373131313131316363636363636363373737313131")
    (hex 49408 "3137373737373737373737376637373766666666656565653131313030303030303030313731623030303033373162303030303030300a30303030323130303030303132623131306230303062303030303030303031313165656566666666666666666637373737373737373737313131313163636363636363633737313131313737373737373737376637373766663766666665656565313131303030313030303030313133333130303030333730303030303030300a303030303030303030303062313131623031306230303062303130303030303131316565656566666666666637373737373737373737373731313131316363636363313131313131")
    (hex 49664 "37373737373737373766666637373737666666666565656531313330333030303030333033313131313130303030303033303030303030300a30303030303030303030303031313231303030303030303030303030303030303131316565656566666666666637373737373737373737373731313131313131313131313131373737373737373737373737373766373766666665656565653131336262623030303033626262303231313030303030303030303030303030300a30303030303030303130303031313131303030303030303030303030303030303031313165656565666666666666376637373737373737373737373731313131313131373737")
    (hex 49920 "373737373737373737373737373737666666666565656565333133313731623030303030373162313131303030303030303030303030303030300a30303030303030303031313032313130303030303030303030303030303030303030313165656565656566666666393737373737373737373737373737373737373737373737373737373737373737373737376666666665656565656533626262303033333362333330303333313131303030303030303030623030306230300a3030306230303062303030303031313030303030313130303030303030303030303030313131653965656561666639666637373737373737373737373737373737373737")
    (hex 50176 "3737373737373737373737373337666633666565336565313131373162303030303337316230303030313130303030303030306230303062303030620a30623030306230303062303030313030303030313161303030303030303030303030303031616165656565656565666666663737373737373737373737373737373737373737373737373737373733376666336665653365656533313131313333303030303033373030303031313131303030303030303030303030303030300a303030303030303030303030303030303030313030613030613030306130303061303030393939393165656565656565656666373737373737373737373737373737")
    (hex 50432 "37373737373737373737373737666665656565656565313131313131303030303030303030303330303131313131303031303030303030303030303030300a30303030303030303030303030303030303630303931303030303061303030306161393961616139396131656565373765656166663737373737373737373737373737373737373737373737376666666565373765653131313131313130303030303030303030303030303131313130303131303030303030303030303030300a30303030303130303030303030313130303030303039393939303030306130303961616137373737616131393165616565656565666637373737373737373737")
    (hex 50688 "373737373737373737373766666565656537656565313131313131303030303030303030303030303130333331313333313130303030303030303333303033330a30303030303133303330303130303331336130393961616161393930303030363961373737373737373761393961656565656565656565653737373737373737373737373737373737656565656565656565653131313131313130303062303030623030306230303033336233336233333130303030303030333362333362330a3030303030336262623030313033626262613039613737373761393030613039396161616137373737373761616139393165656565656565656565656565")
    (hex 50944 "6565656565656565656565656565656565656531313131313131303030623030306230303062303030623033626262626262333030303030303030336262626262620a30303330333037316230303130303731623139613737373737376139303039616137373737616137373737376137616139396131656565653765653737653737373737653737656537656565656565313131313131313030303030303030303030303030303030303033623737313762333030303030303030336237373137620a303362626230303333336233333031333331396137373737373761393039613737373737373737613737373761373737616139313131316565656561")
    (hex 51200 "65656565656565656565656565613131313131313131313131303030303030303030303030303333303033333031623731313762303030303030303030306237313137620a30303731623030303033373162303130303139613737373737376139396137373737373737373737613737373761373737613939316131316137373737313161313131313131316131313131313131313131303030303030303030303030303030333362333362333330303337373330303033333030333330303033373733300a30303033333030313030333730303030303039613737373737376139396137373737373737373737613737373761373737393931316131616139")
    (hex 51456 "613937613131313131313161316139616139613131313737303030303030303030303030303030336262626262623330333033333033303333623333623333303330333330330a30303030303030303030303033303030613131396137373737613939613737373737373737373737376137373761393737376161303961373737376161393161313131313139613737376137613930373737303030303030303030303030303030336237373137623331333030303033303362626262626233303330303030330a3030303030303030303030303130303031313131396161616139393961373737373731373737373737613737376139616139393930396137")
    (hex 51712 "6137373761376161396161393737373737613737373961303730303030303030303030303030303030306237313137623030303131313131303362373731376233303030303030300a30303030303030313030303030303930313131313139393961616161613737373737323137373737376137376137613737376139613737373737613737373737613737613937373737373737376139343737303030303030303030303030303030303033373733303030303130303130303062373131376230303030303030300a303030303030303030303030303030303131613131313961373737376137373737373732323737373761376137376137373761393737")
    (hex 51968 "37373737373737373737393737376137373737613737373935373737323234303030303030303030303030303330333330333030303030313031303130333737333030303030303030300a30303030303030313030303130303131613131316139613737373737376137373737373732313737616161373737393737373961373737373737373737373761613939613761373737376639396530373939393932323030303030303030303030303330303030333130303031313130303133303333363330303030303030300a30303030303030303030303031313131313131313139613737373737376137373737373737323137613737373737373739613737")
    (hex 52224 "373737373737613737373739393731373761616161376666343930613961343430303032303030303030303030303030303030303031303030303030303033303030303330303030303030300a30303030303030303030303131313131313131313139613737373737376161373737373737323230313737373737376161373737613737373737376137376137323239616137376137666666666161343432343230303032303030303030363030303031303030303030303030303030303131303030303030303030303030300a3030303030303030303030303131313131303131313939373737373737613961613737373761323130613737373761613131")
    (hex 52480 "3131316161616139373739373732323737373737373737666666616634343232323032303030303030303030303030303031303030303030303030303031313030303030303030303030303030300a30303030303030303030303131313131303030613131396137373737613931393961616161393932303131616161313131376331633131376137373734303232373737373737373766666666666661393234303030303030303030303030303130303030303030303030303030303131303030303030303030303030303030300a303030303030303030303030313031313030303031313139616161613931313930393939393030303030313531313163")
    (hex 52736 "31313131313131313737303032326637663737373737373766666666666639393430323230303030303030303030303030303130303030303030303030303031303131303030303030313030303030300a30303030303030303030303030303131616161313131316161393939303031313030303061323231303035313131313131303130313030313130303032666666373737373737376666666666666634343030303230303030303030303030303030313030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303161313131303030303030616130303037383832313131323131")
    (hex 52992 "313132313132323132313130303566346666376637373737666666666666653434343430303030303030303030303030303031303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303031316130303030303030303731323838323131323231303063633031313032313130303566323637663766663766663766666666666139343430303030303630303030303030303130303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030313031303031313030306137373032383832313232")
    (hex 53248 "3030306337376330313031323231353531346666666137666666376666666666663939393430303030303030303230303030303030303030303030313030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030616137613030323838383232303131633737373763313032313231303232343466666537616666666537666666666634343434303030303030303030303030303030303630303030303030303030303030303030303130303030303030303030300a303030303030303030303030303030303030303030303130303030303030613737613131303238383232")
    (hex 53504 "32303135633737373763353130323232323838343966666561376166663466666634666666653632323036303030303030303030303030303030303030303030303030303030303030313030303030303030303030300a30303030303030303030303030303030303030303030303131303030306137373761313130303232383131303131306337376335313530323132383838393966343465373761663466666632346534343432343430303030303030303031303030303030303030303030303030303030303030303131313030303030303030300a30303030303030303030303030303030303131303030303631303030613737376131303131323838")
    (hex 53760 "383131303135303063633035313531303232383834613966323466613761653234666532306539303434323236303030303030303130303030303030303030303030303030303030303030303030303130303030303030300a30303030303030303030303030303030303130303030303030303061373737613030303032323838313063633031643030303131633135313034323234343934303530613737613234656634303534303034343230303030303030303030303030303030303030303030303030303030303030303030313030303030303030300a3030303030303030303030303030303030303030303030303061613737376130313030303238")
    (hex 54016 "3832306337376330303130313063636330313530383230323432306630306137376134346532303032323030323230303030303030303130303030303030303030303030303030303031303030313030303030303030303030300a30303030303030303030303030303030303030303030313061373737376130313130313132383832633737373763303030316337373763303130383232323030303434306137376134303430323030313030303031303030303130313130303030303030303030303030303030303030303031303030303030303030303030300a303030303030303030303032343434326565656565656565653737376131303131303031")
    (hex 54272 "32383131633737373763303131636337373763633130383232323230303130303261373761303430323030313030303030303030313030303030303030303030303030303030303130303030313030303030303030303030303030300a30303030303030303030303030303032323238383838383838656565656565656565656565653235316337376330643064316337373763303130383230323030303030303261373761323434323030303131303030303031313031303131303031303030303030303030303131303030303130303030303030303030303030300a30303030303030306430303030303030303032323232323838383838383838383838")
    (hex 54528 "383865653231363063633031353064313063636330313130383236303030303030303230613737613431313230303030303030303031303030303030303030303030303030303130303130303030303031303030303030303030303030300a30303030303030303030303030303030303031303031313232323838383838383838383838653230643130303031303064353030633030313130323232323030303030323231613737376131303030303131313030313031313131303130303130303030303030303031303130313130303030313030303030303030303030300a3030303030303030303030303030303130303130303232313132323231323232")
    (hex 54784 "3232323232383531313131313030303030643130303535303032323032323231313131313131306137373761303131313130303030303131313131313030313030303030303130303030303130303131303030303030303030303030303030300a30303030303030303030303030303030303030303031323232313131313131313131323232323531353130303030303030306431313130303132323232313131313131313130313061373737613131313131303030303131303131313131313030303030303030303030313030303030303030303130303030303030303030300a303030303030303030303030313130303030303030303031313131313131")
    (hex 55040 "31313131313131323131313131303030303030303031313030303132323232323265656565653030303061373737613231313131313030303031303030303130303030313030303130303030303130303030313030303131303030303030303030300a30303030303030303030303031313030303030303030303131313131313131316331313131313131313031313131313131313131313131313032323232313838383838383838386565656565613131303131313131313131313030303031313030303031313030303030303131303030313130303031303030303030303030300a30303030303030303030303030303030303030303030303131313131")
    (hex 55296 "313131313131313131313131313030303030313131313131313131313030303031323232383838383838383838383838386565656531303030303131313030303131303030303031313130303030303131303030313130303030303030303030303030300a30303030303030303030303030303030303030303030303030303030313131313131313131313030313131303030303030303030303130303030313131313132323231313232323232323838383838383838343230303030303030313131303130303031303130643030303031303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030")
    (hex 55552 "3031313131313131313131303030303131303030303030303030303030303131313130303031303031303031313032313132313132323232323230303030303031313030303030303031303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030313131313131313130303030303030303130303030303030303030303031303130303131313131313030303031323231323130313130313030303030303030303030313030303030313031303030303030303130303030303030303030303030303030300a303030303030303030303030303030313030303030303030")
    (hex 55808 "30303131313131313131313131303030303030303030303131303030303030303030303131313131313131313131313131313232313131313030303131313030303030303030313030303030313131313030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303031313131313131313131313130313030313030303030303030303031303030303031313131313131313131313131313131313131313030313030303031303030303030303030303030303030303131303031303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030")
    (hex 56064 "303031303131303131313130303030303030303030303030303030303030303030303031303031313131313131313131313131313131313131303031313030303130303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030313030313130313130303030303030303030303030303030303030303030313030313131313031313131313131313131313131313130303030303031303030303030303030303030303030303030303030303030303030303130303030303031303030303030300a3030303030303030303030303030303030303030")
    (hex 56320 "3030303130313030313031303031303030303030303030303030303130303030303030303030313130303131313131313131313131313131313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030313030303030303030303030303030303030303030303131313131313131313131313030303030303031313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030")
    (hex 56576 "30303030303030303030303030303030303030303030313030303030303030303030303030303030303030303031313131313131313131303030313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303064303030303030303030303030303030303030303030303030303030303030303030303030313030303031313130313131313131313131303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030")
    (hex 56832 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030313030313131313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030313030303130303030313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030")
    (hex 57088 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030313131303030303030313030303030303030303030303030303030303030303031303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030313030303030313030303030303030303030303030303030303030303030303030303030303030303031313130303130313030303130306430303030303030303630303030303030303030303030303030303030303030303030303030303030303030303030300a0a5f5f7366785f5f0a303030")
    (hex 57344 "3130303030333435323033323532303330353230326535323032623532303238353230323535323032323532303230353230316235323031383532303136353230313335323031313532303031303230306635323030633532303061353230303835323030363532303035353230303435323030333531303031353230303035323030303030303030303030303030303030303030303030303030303130303030303030300a303030313030303032623635303336363430326436353032353635303230363330316436323031373632303135363230313136323030663631303064363130306136313030373631303035363130303436313030333631303032")
    (hex 57600 "3631303032363030303136303030303630303030363030303036303030303630303030363030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303130303030333737353030383635303332353530323036333030643632303038353230303836323030373632303035363130303436353030343631303032363030303236303030313630303030363230303037303030303730303030363330303036303030313630303031363230303136303030313630303031363230303037303030303730303030373030303037303030303730303030373030303037303030303730300a3030303130303030")
    (hex 57856 "303936313032353632303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630300a3030303630303030303130353031363035303139303530313630353031393035303031303530313630353031393035303136303530313930363031623036313162303631316230363132393030303164303030313730303032363030303031")
    (hex 58112 "303530313630353031393035303136303530313930353030313035303136303530313930353031623036313162303631316230353031623035303162303430316230333031623032350a3030303630303030323035343031643534303230353430316435343032303534303164353430323035343031643534303232353430323235353032323535303232353530323235353030303030303030303030303030303030303030303235353334323235333032353533303232353330323535333031643533303235353330323235333031393533313237353332323735333032373533303237353332323735333032373533300a30303036303030303139373230")
    (hex 58368 "32303732303232373230316237333032303733303139373330323037343032323734303162373430323037343032323734303232373430323237343030303030303030303030303030303030303030303136373230323037323032353732303162373330323537333031393733303235373430323237343031623734303237373430323237343032373734303237373430323737343032373734300a30313130303030303166353530316635353031623535303164353530316435353032303535303166353530316635353031623535303161353530316235353031643535303166353530316635353031623535303164353530316435353032303535303166")
    (hex 58624 "35353031623535303161353530316235353031643535303166353530323735353032373535303235353530323335353032333535303232353530323035353032303535300a3031313030303030306635353030663535303061353530306635353031623533303136353530316235353031623535303136353530306635353030663535303061353530306635353030663535303061353530303535353030613535303065353530306635353030663535303136353530316235353031623535303136353530313735353031373535303132353530306635353030663535303132353530313035353031303535300a303131303030303031653535303163353530")
    (hex 58880 "3163353530313735353031653535303162353530323035353031643535303232353530316535353032333535303230353530316335353032363535303236353530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303131303030303031373535303134353530313435353031303535303137353530306235353031393535303064353530316235353030663535303163353530313035353030343535303136353530313635353030303030303030303030303030303030303030303030")
    (hex 59136 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3039306430303030316230303031623030303162303030316430303031623033303162303030316230323031643032303165303330323030333032303034303230303430316530303032303030303230303030323030303031623730303164373030316237303031623730303162373030316437303032323730303161373030316237303031623730303136373030316237303031623730303162373030316337303031633730300a3035306430303030316635303031663030303166353030")
    (hex 59392 "323135303031663533303166303030316635323032313532303232353330323435333032343533303234353330323235303032343530303234353030323435303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031306430303030323230303032323030303232303030323430303032323033303232303030323230333032343033303235303330323730333032373033303237303330323530303032373030303237303030323730303030303030303030303030303030303030303030303030")
    (hex 59648 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3464313030303030326230323032623032303262303230326230323032623032303262303230326230323032623032303262303230323930323032623032303263303230326230323032623032303262303230323630323032363032303236303230323730323032373032303237303230326230323032623032303262303230326130333032613033303261303330323730333032373033303237303330323030333032303033300a34643130303030303230303330323830333032383033303263303330")
    (hex 59904 "32613033303261303330326130333032373033303237303330323730333032633033303261303330323930333032653033303265303330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30313066303030303165303530303030303031653035303164303530316230353031613036303161303632316130363230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 60160 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3035306630303030316235343030373030303162353430316135343031383534303137353530313735353231373536323037353030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030300a303130633030303032393035303263303030326130303032393035353239303535")
    (hex 60416 "3261303030323730353032393030303234303030323930303032373035303234303030323430303032343030303237303530323430303032613035303234303030323430303032613035353261303535323430303032393035303234303030323430303032343030303239303530323430303032613030303239303030323430353032363230300a353130633030303031343331353139333135323033323531343332353139333135323033313531343332353139333235323033313531343331353139333235323033323531343331353139333135323033323531343332353139333135323033313531343332353139333235323033313531343331353139")
    (hex 60672 "3332353230333235313433313531393331353230333235313433323531393331353230333135313433323531383332350a3031306330303030303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735303031373530303137353030313735300a3031306330303030313935353032633530303261353030313935353531393535353261353030")
    (hex 60928 "313835353032393530303234353030323935303031383535303234353030323435303032343530303138353530323435303031623535303234353030323435303031623535353162353535323435303031393535303234353030323435303032343530303139353530323435303032613530303239353030313835353032363530300a3031306330303030323930353032633030303261303030323930353532393035353261303030323730353032393030303234303030323930303032303030303234303030323430333532353034353237303530323430303032613035303234303030326630303532643035353263303535323430303032393035303234")
    (hex 61184 "303030323430303032343030303234303030323430303032343033303235303432323930353032363230300a3031306330303030313935353032633530303261353030313935353531393535353261353030313835353032393530303234353030323935303032303530303234353030313435333531363534353138353530323435303031623535303234353030326635303531653535353164353535323435303031393535303234353030323435303032343530303234353030323435303031343533303136353430313935353032363530300a30313063303030303263303530323430303032343030303261303535323930353532343030303265303530")
    (hex 61440 "32343030303234303030323930303032373035303234303030323430303032343030303265303530323430303033303035303234303030323430303032653035353264303535323430303033303035303234303030323430303032393030303239303530323430303032373030303261303030323930303032383030300a35313063303030303134333135313933313532303332353134333235313933313532303331353136333235313933323531363331353138333135313933323531363332353138333135313933313531363332353138333235316233313531653331353138333235316233323531653331353138333135316233323531653332353138")
    (hex 61696 "33313531623331353164333235313833323531623331353164333135313833323531623332350a3031306330303030303137353030313735303031373530303137353030313735303031373530303137353030313735303033373530303337353030333735303033373530303337353030333735303033373530303337353030363735303036373530303637353030363735303036373530303637353030363735303036373530303537353030353735303035373530303537353030353735303035373530303537353030353735300a303130633030303031643535303234353030323435303031623535353139353535323435303031653535303234353030")
    (hex 61952 "3234353030323935303031363535303234353030323435303032343530303165353530323435303031653535303234353030323435303031643535353162353535323435303031643535303234353030323435303032393530303138353530323435303032373530303261353030323935303032383530300a313130353030303033383536323335353532333335353233313535323266353532326435353232623535323239353432323735353232363535323233353532323235353232313535323165353432316435343231613534323138353432313735343231353534323134353432313235343231303534323065353432306435333230623533323039")
    (hex 62208 "3532323037353132303535313230333531323031353132303035313230303531320a3438303230303030313733353230663330323131333432303933323230383332323037333230303733353030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430300a3038306330303030313330353631373036363163303636323030363632323033363239303536333130333633323030363336303036")
    (hex 62464 "333230303632373030363166303036313930303631373030303132303030326130303032373030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030306130303030303730353630633036363066303736313630373631383036363166303536323230343732373033373333303337333330353733633036373365303036326230303632353030363230303036316230303631373030363134303036313130303630663030363064303036306330303630613030363039303036303630303630363030363035")
    (hex 62720 "303036303530303630303030303030303030303030303030303030300a3030303430303030303734343030373432303037343230306134303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430300a34613032303030303263363431326636363133303636313331363631333736363133323636313332363631326236363132383636313235363731")
    (hex 62976 "32323636313165363631313436363131613635313136363531303836343131313634313035363431306336343130353634313034363431303236343130323633313032363331303136333130313632313030363231303036323130303631313030363131303036313130303631310a30313031303030303039313430303831353030383136303066313630313231343030663134303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 63232 "30303030303030303030303030303030303030303030300a3032303430303030336236373032623634303362363730323136323033373637303238363730333136373032363635303263363530326136353032373635303235363530323236353032303635303164363530316236353031393635303137363430313636343031343634303132363430313036343030643634303063363330306136333030383632303037363230303536323030343632303032363230303136323030303632300a303130613030303030633432303063343230306334323030633432303063343230306334323030633432303063343230306634323030663432303066343230")
    (hex 63488 "3066343230306634323030663432303066343230306634323031303432303130343230313034323031303432303130343230313034323031303432303130343230313434323031343432303134343230313434323031343432303134343230313434323031343432300a303130613030303030353332313035333230303533323030353332303035333230303533323030353332303035333230303833323030383332303038333230303833323030383332303038333230303833323030383332303039333230303933323030393332303039333230303933323030393332303039333230303933323030643332303064333230306433323030643332303064")
    (hex 63744 "3332303064333230306433323030643332300a3030306130303230333436313532393631353262363136316536303631633634303164363435326236313532373630353238363135323936313532623631353165363030316336343031643634353262363135323736313533343631353239363135326236313631653630363163363430316436343532623631353237363035323836313533353631353262363135316536303531633634303164363435326236313532373631350a3035306130303230303233323030323332303032333230303233323030323332303032333230303233323030323332303032333230303233303530323332353032333235")
    (hex 64000 "303233323030323332353032333230303233323530333332303033333230303333323030333332303033333230303333323030333332303033333230303733323030373332303037333230303733323030373332303037333230303733323030373332300a3031306130303030303233323030323332303032333230303233323030323332303032333230303233323030323332303061333230306133323030613332303061333230306133323030613332303061333230306133323030353332303035333230303533323030353332303035333230303533323030353332303035333230303333323030333332303033333230303333323030333332303033")
    (hex 64256 "333230303333323030333332300a3031306130303030303932323030393232303039323230303932323030393232303039323230303932323030393232303065323230306532323030653232303065323230306532323030653232303065323230306532323030613232303061323230306132323030613232303061323230306132323030613232303061323230303032323030303232303030323230303032323030313232303031323230303132323030313232300a30313061303030303035323230303532323030353232303035323230303532323030353232303035323230303532323030653232303065323230306532323030653232303065323230")
    (hex 64512 "30653232303065323230306532323030613232303061323230306132323030613232303061323230306132323030613232303061323230303032323030303232303030323230303032323030313232303031323230303132323030313232300a30313061303030303064323230306432323030643232303064323230306432323030643232303064323230306432323030353232303035323230303532323030353232303035323230303532323030353232303035323230313132323031313232303131323230313132323031313232303131323230313132323031313232303033323230303332323030333232303033323230303332323030333232303033")
    (hex 64768 "32323030333232300a3135306130303030313532323031353232303135323230313532323031353232303135323230313532323031353232303135323230313532323031353232303135323230313332323031333232303135323230313532323031363232303136323230313632323031363232303136323230313632323031363232303136323230313932323031393232303139323230313932323031393232303139323230313932323031393232300a313530613030303031613232303161323230316132323031613232303161323230316132323031613232353161323235316432323031643232303164323230316432323031643232303164323230")
    (hex 65024 "3164323230316432323031393232303139323230313932323031393232303139323230313932323031393232303139323230313632323031363232303136323230313632323031363232303136323230313632323031363232300a313530613030303031393232303139323230313932323031393232303139323230313932323031393232353139323235313132323031313232303131323230313132323031313232303131323230313132323031313232303164323230316432323031643232303164323230316432323031643232303164323230316432323031383232303139323231316132323131643232313231323231323532323132363232313236")
    (hex 65280 "3232310a3039306130303030316432313731613231373231323137323232313732393231373236323137326432313732653231373164323137316132313732313231373232323137313132313730653231373135323137313632313731643231373161323137323132313732323231373239323137323632313732643231373265323137316432313731613231373231323137323232313731313231373065323137313532313731363231370a3039306130303030323932313732363231373264323137326532313733353231373332323137333932313733613231373239323137323632313732643231373265323137316432313731613231373231323137")
    (hex 65536 "323232313731313231373065323137313532313731363231373164323137316132313732313231373232323137313132313730653231373135323137313632313730353231373032323137303932313730613231370a3031306130303030306530303332393630303065303033316536303032383631353164363035326236303532373631353065303033323936303532623631353165363030323836313531643634353262363135323736303531663635303166363330316636323031653630303166363235316636323531663632353237363035306530303333353630353262363035316536303531303631313163363131323836323133333633310a35")
    (hex 65792 "63303330303030313331323132353133313331313531333831373131623136313362313531336231343133633134313136313431323931343133393133313335313331333231333132643133323238313332323231333231633133323136313332313331333231643133323065313332306431333230613133323039313332303831333230363132323035313232303431323230333132323033313232303331323230313132300a35633034303030303038313731323031363131383136313066313731303831373131373137313130313731303931373130373137313064313631306631363130393135313037313531303631353130353134313035313431")
    (hex 66048 "30353133323034313332303331333230323133323032313332303131333230313133323030313332303131333230313133323031313332303131323230303132323030313232303031323230303132320a5f5f6d757369635f5f0a30342030343035303634340a30302030373038343734390a30342030393061343834610a30342030623063306434340a30302030653038343334340a30342030663061343334340a30342031303131346534340a30312031323133313431350a30302031363133313431370a30322031383139316131620a30302032343235363834340a30312032363237323834340a30302032363238323936360a303020323632373261")
    (hex 66304 "36350a30302032363261326236350a30302032363237326334340a30302032363239326434340a30302032363237326334340a30302032363261326534340a30302032383239326634340a30302032383239333034340a30302032373262326634340a30322032353234333134340a0a")))
