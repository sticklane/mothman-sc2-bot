#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : Birds With Guns (birdswithguns-5.p8)
;; Source ROM : assets/roms/pico/birdswithguns-5.p8 (94046 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "super_hot")
  (title "Birds With Guns (birdswithguns-5.p8)")
  (rom-source "pico/birdswithguns-5.p8")
  (rom-bytes 94046)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label gff map sfx music))
    (lua-line-count 2487)
    (lifted-function-count 99)
    (gfx-row-count 128)
    (map-row-count 32)
    (gff-row-count 2)
    (sfx-row-count 54)
    (music-row-count 35))
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
    (lifted-functions (_draw _init _update60 allbtn animexplo animplayer begin_boss begin_game break_crate burst_ptc cansee canshoot changedirection check_flag circ_coll clone_room collide collision copy coupdekak debug_ delchecker dist draw draw_bar draw_bullet draw_death_menu draw_drops draw_enemy draw_ghost_connector draw_logo draw_main_menu draw_map draw_player draw_player_ui draw_ptc draw_random draw_weel drawgrass gen_train get_traj grasstile init_boss_room init_enemies init_menus init_player init_ptc initguns is_solid isleft killbarelle knockback_enemy knockback_player loaded make_boss_death make_btn make_death_menu make_drop make_enemy make_gun make_main_menu make_ptc mouse_x_y nextgun oprint ospr oxxl parcourmap player_update rafale rect_overlap rnd_gun rrnd sapwnrndenemy set_stats shoot shoot1 spawn_bullet spawn_enemy spawn_loot swichtile touches_rect update update_boss update_bullet update_camera update_death_menu update_door update_drops update_enemy update_gun update_main_menu update_ptc update_room updaterafale wide))
    (pico8-api-calls (abs add all atan2 btn btnp camera ceil circ circfill cls cos del fget flr line map max mget mid min mset music pal palt peek poke print rectfill rnd sfx sin spr sqrt))
    (structured-loops 35)
    (structured-conditionals 85)
    (lifted-state-machines 2)
    (lifted-high-level-idioms 6)
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 32)
    (active-sfx-lifted 32)
    (active-music-lifted 23))
  (pico8-state-machines
    (def-pico-state-machine pico8_lifecycle_fsm #:hooks (_init _update _draw) #:update-states (_update60 animplayer begin_game draw_death_menu draw_main_menu draw_player draw_player_ui init_menus) #:draw-states (_draw draw draw_bar draw_bullet draw_death_menu draw_drops draw_enemy draw_ghost_connector))
    (def-pico-state-machine pico8_entity_dispatch_fsm #:mechanism foreach-all-iterator #:registered-handlers (_draw _init _update60 allbtn animexplo animplayer begin_boss begin_game break_crate burst_ptc)))
  (high-level-idioms
    (idiom-pico8-entity-iterator #:apis (foreach all add del) #:call-sites 47)
    (idiom-pico8-tilemap-collision #:apis (mget fget map) #:call-sites 23)
    (idiom-pico8-sprite-batch-render #:apis (spr sspr pal palt cls) #:call-sites 83)
    (idiom-pico8-fixed-point-physics #:apis (flr sin cos abs min max) #:call-sites 146)
    (idiom-pico8-input-poll #:apis (btn btnp) #:call-sites 15)
    (idiom-pico8-audio-trigger #:apis (sfx music) #:call-sites 30))
  ;; --- 4. Symbolic MMIO Cross-Reference, State Machines, Idioms & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function #:params () #:returns ()
      (name _init)
      (params ())
      (returns ())
      (line-range (18 88))
      (api-calls (pal poke))
      (called-functions (begin_game gen_train init_enemies init_menus init_player init_ptc initguns parcourmap update_room))
      (structured-ast
        (seq-block 71))
      (decompiled-pseudo-code
        (set! keyboard #f)
        (call initguns)
        (set-values! (enemies checker) ((table) (table)))
        (set-values! (mx my) (0 0))
        (set-values! (solid breakable spawnable lootable notbulletsolid) (0 1 2 3 4))
        (set-values! (shake camy camx targetcamx) (0 0 0 0))
        (set! cam_follow_player #t)
        (set! trainpal split)
        (set-values! (pal_n menu) (1 "main"))
        (set! actors (table))
        (call init_enemies)
        (call init_player 111)
        (call init_ptc)
        (set-values! (wl diffi) (4 20))
        (set-values! (wagon_n trainlen) (0 6))
        (set! tl trainlen)
        (call gen_train)
        (call update_room)
        (set-values! (random enemies) ((table) (table)))
        (call parcourmap)
        (set! drops (table))
        (call init_menus)
        (set-values! (birdchoice hardmodetimer) (0 0))
        (set-values! (ofsetboss bullets_shooted bullets_hit) (0 1 1)))
      (body-lines
        "function _init()"
        "\tkeyboard = false"
        "\tinitguns()"
        "\tenemies,checker = {},{}"
        "\t--mouse"
        "\tmx,my=0,0  "
        "\t"
        "\t--flags"
        "\tsolid,breakable,spawnable,lootable,notbulletsolid=0,1,2,3,4"
        "\t"
        "\t--camera"
        "\tshake,camy,camx,targetcamx=0,0,0,0"
        "\t"
        "\tcam_follow_player=true"
        "--\ttrainpal = {{8,2},{11,3},"
        "--\t{7,13},{12,13},{10,9},{0,2}}"
        "\t"
        "\t-- zep:"
        "\ttrainpal = split\"8,2,11,3,7,13,12,13,10,9,0,2,8,2\""
        "\t"
        "\tpal_n,menu = 1,\"main\""
        "\t"
        "\tactors = {}"
        "\tinit_enemies()"
        "\tinit_player(111)"
        "\t"
        "\tinit_ptc()"
        "\twl,diffi = 4,20"
        "\t"
        "\t--wagon length"
        "\twagon_n,trainlen = 0,6"
        "\ttl = trainlen"))
    (def-pico-function #:params () #:returns ()
      (name _update60)
      (params ())
      (returns ())
      (line-range (92 97))
      (api-calls (peek poke))
      (called-functions (mouse_x_y))
      (structured-ast
        (for-loop "i=0x3100,0x3148"))
      (decompiled-pseudo-code
        (call mouse_x_y)
        (for-range i 12544 12616 (call poke i (call peek i))))
      (body-lines
        "function _update60()"
        "\tmouse_x_y()"
        "\tfor i=0x3100,0x3148 do"
        "\t\t--on"
        "\t\tpoke(i,peek(i)&0b10111111)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name _draw)
      (params ())
      (returns ())
      (line-range (173 204))
      (api-calls (camera cls print))
      (called-functions (draw_map drawgrass rrnd))
      (structured-ast
        (if-cond (== keyboard #t))
        (if-cond (and (== wagon_n 0) (== menu "game")))
        (if-cond keyboard))
      (decompiled-pseudo-code
        (let ([ox (call rrnd shake)] [oy (call rrnd shake)]) (call camera (+ camx ox) (+ camy oy)))
        (call cls 15)
        (call drawgrass)
        (call draw_map)
        (when (and (== wagon_n 0) (== menu "game")) (set! s (aref |[| void)) |[| (aref or s) move |[| |[| weapon |]| (when keyboard (set! s (aref |[| void))) move x c weapon |]| (call print s 33 42 2)))
      (body-lines
        "function _draw()"
        "\tlocal ox = rrnd(shake)"
        "\tlocal oy = rrnd(shake)"
        "\t--if (keyboard == true) "
        "\tcamera(camx+ox, camy+oy)"
        "\t"
        "\tcls(15)"
        "\t"
        "\t--draw map"
        "\tdrawgrass()"
        "\t"
        "\tdraw_map()"
        "\tif wagon_n==0 and menu==\"game\" then"
        "\t\tlocal s= [["
        "  ⬆️        [e]"
        "⬅️⬇️➡️ or [s d f] "
        "     move "
        ""
        "[click]  shoot"
        "[scroll] change "
        "          weapon"
        "\t\t]]"
        "\t\tif(keyboard)s=[["
        "    ⬆️"
        "  ⬅️⬇️➡️ move "
        ""
        "  ❎ (x) shoot"
        "  🅾️ (c) change "
        "         weapon"
        "\t\t]]"
        "\t\tprint(s,33,42,2)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name set_stats)
      (params ())
      (returns ())
      (line-range (238 247))
      (api-calls (flr))
      (called-functions ())
      (structured-ast
        (if-cond (< (modulo t 60) 10)))
      (decompiled-pseudo-code
        (set! (-> stats :time) (call flr void))
        (* (- (call time) (-> stats :time)) 10)
        (let ([t (-> stats :time)] [s ""]) (when (< (modulo t 60) 10) (set! s "0")))
        (set! (-> stats :time) (call tostr t))
        (set! (-> stats :wagon) (string-append (call tostr (+ wagon_n 1)) "/7")))
      (body-lines
        "function set_stats()"
        "\tstats.time=flr("
        "\t (time()-stats.time) * 10) / 10"
        "\tlocal t = stats.time"
        "\tlocal s = \"\""
        "\tif(t%60 < 10) s=\"0\""
        "\tstats.time= tostr(t\\60)..\":\"..s..tostr(t%60) "
        "\t--stats.time=(flr(stats.time)\\60)+((flr(stats.time)-(flr(stats.time)\\60)*60)/100)"
        "\tstats.wagon=tostr(wagon_n+1)..\"/7\""
        "end"))
    (def-pico-function #:params () #:returns ()
      (name begin_game)
      (params ())
      (returns ())
      (line-range (249 256))
      (api-calls (flr music rnd sfx))
      (called-functions ())
      (structured-ast
        (if-cond (== b 0)))
      (decompiled-pseudo-code
        (call sfx 37)
        (call music)
        (let ([b (or birdchoice 0)]) (when (== b 0) (set! b (+ (call flr (call rnd 12)) 1)))))
      (body-lines
        "function begin_game()"
        "\tsfx(37)"
        "\tmusic()"
        "\t"
        "\tlocal b=birdchoice or 0"
        "\tif b == 0 then"
        "\t\tb=flr(rnd(12))+1"
        "\tend"))
    (def-pico-function #:params (a) #:returns (val)
      (name isleft)
      (params (a))
      (returns (val))
      (line-range (274 276))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr (< a |.|)))
      (decompiled-pseudo-code
        (return (< a |.|)))
      (body-lines
        "function isleft(a)"
        "\treturn a<.75 and .25<a"
        "end"))
    (def-pico-function #:params (s x y col) #:returns ()
      (name ospr)
      (params (s x y col))
      (returns ())
      (line-range (278 281))
      (api-calls (pal))
      (called-functions ())
      (structured-ast
        (for-loop "i=0,15"))
      (decompiled-pseudo-code
        (for-range i 0 15 (call pal i col)))
      (body-lines
        "function ospr(s,x,y,col)"
        "\tfor i=0,15 do"
        "\t\tpal(i,col)"
        "\tend"))
    (def-pico-function #:params (t x y col ocol) #:returns ()
      (name oprint)
      (params (t x y col ocol))
      (returns ())
      (line-range (293 298))
      (api-calls (print))
      (called-functions ())
      (structured-ast
        (seq-block 6))
      (decompiled-pseudo-code
        (set! ocol (or ocol 1))
        (set-values! (for) ((- 1) 1))
        (set-values! (for) ((- 1) 1))
        (call print t (+ x i) (+ y j) ocol))
      (body-lines
        "function oprint(t,x,y,col,ocol)"
        "\tlocal ocol = ocol or 1"
        "\tfor i=-1,1do"
        "\t\tfor j=-1,1do"
        "\t\t\tprint(t,x+i,y+j,ocol)"
        "\t\tend"))
    (def-pico-function #:params (t) #:returns ()
      (name copy)
      (params (t))
      (returns ())
      (line-range (305 309))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "k,v in pairs(t)"))
      (decompiled-pseudo-code
        (set! n (table))
        for
        (set! (aref n k) v))
      (body-lines
        "function copy(t)"
        "\tlocal n={}"
        "\tfor k,v in pairs(t) do"
        "\t\tn[k] = v"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name update_camera)
      (params ())
      (returns ())
      (line-range (313 329))
      (api-calls (mset poke))
      (called-functions ())
      (structured-ast
        (if-cond (> px (* 128 (- wl 1))))
        (if-cond (!= wagon_n (- tl 1))))
      (decompiled-pseudo-code
        (let ([px (-> p :x)] [wl wl] [maxlen 240]) (call poke 24387 0))
        (when (> px (+ (* 128 (- wl 1)) 8)) (set! cam_follow_player #f) (set! targetcamx (* 128 (- wl 1))) (when (!= wagon_n (- tl 1)) (quote (nop)))))
      (body-lines
        "function update_camera()"
        "\tlocal px = p.x"
        "\tlocal wl = wl"
        "\tlocal maxlen = 240"
        "\t"
        "\t--poke(0x5f40,0)"
        "\tpoke(0x5f43,0)"
        "\tif px > 128*(wl-1)+8 then"
        "\t\t--pan cam to connector room"
        "\t\tcam_follow_player=false"
        "\t\ttargetcamx=128*(wl-1)"
        "\t\t"
        "\t\t--block off old entrance"
        "\t\tif wagon_n != tl-1 then"
        "\t\t\t--mset(48,7,6)"
        "\t\t\t--mset(48,6,13)"
        "\t\tend"))
    (def-pico-function #:params () #:returns ()
      (name draw_ghost_connector)
      (params ())
      (returns ())
      (line-range (356 359))
      (api-calls (map))
      (called-functions ())
      (structured-ast
        (if-cond (< camx 0)))
      (decompiled-pseudo-code
        (when (< camx 0) (call map 0 16 (- 128) 0 16 16)))
      (body-lines
        "function draw_ghost_connector()"
        "\tif camx<0 then"
        "\t\tmap(0,16, -128,0, 16,16)"
        "\tend"))
    (def-pico-function #:params (n) #:returns (val)
      (name rrnd)
      (params (n))
      (returns (val))
      (line-range (362 365))
      (api-calls (rnd))
      (called-functions ())
      (structured-ast
        (return-expr (- (call rnd (* 2 n)) n)))
      (decompiled-pseudo-code
        (return (- (call rnd (* 2 n)) n)))
      (body-lines
        "function rrnd(n)"
        "\t--\"radius rnd\""
        "\treturn rnd(2*n)-n"
        "end"))
    (def-pico-function #:params (b) #:returns (val)
      (name allbtn)
      (params (b))
      (returns (val))
      (line-range (367 369))
      (api-calls (btn))
      (called-functions ())
      (structured-ast
        (return-expr (or (call btn b) (call btn b 1))))
      (decompiled-pseudo-code
        (return (or (call btn b) (call btn b 1))))
      (body-lines
        "function allbtn(b)"
        "\treturn btn(b) or btn(b,1)"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name debug_)
      (params ())
      (returns ())
      (line-range (372 378))
      (api-calls (all))
      (called-functions ())
      (structured-ast
        (seq-block 7))
      (decompiled-pseudo-code
        (let ([p (aref players 1)]) (set! (aref (-> p :gunls) 1) debuggun))
        (set! wagon_n (- tl 1))
        for
        (set! (-> i :destory) #t))
      (body-lines
        "function debug_()"
        "\tlocal p =players[1]"
        "\tp.gunls[1] = debuggun"
        "\twagon_n = tl-1"
        "\tfor i in all(enemies)do "
        "\t\ti.destory = true"
        "\tend"))
    (def-pico-function #:params (bird) #:returns ()
      (name init_player)
      (params (bird))
      (returns ())
      (line-range (385 437))
      (api-calls ())
      (called-functions (copy))
      (structured-ast
        (for-loop "i=1,#bird_stats,13"))
      (decompiled-pseudo-code
        (set! b 0)
        (set! dx1 1)
        (set! dy1 0)
        (set! p (table))
        (set! n 1)
        (set! agro 9999)
        (set-values! (x) ((- 64) y))
        (set-values! (dx) (0 dy))
        (set! a 0)
        (set! spd |.|)
        (set! fric 0.75)
        (set-values! (bx) (2 by))
        (set-values! (bw) (4 bh))
        (set-values! (hx) (2 hy))
        (set! hw 4)
        (set! life 10)
        (set! maxlife 10)
        (set! ammo 250)
        (set! maxammo 250)
        (set! spr bird)
        (set! gun nil)
        (set! gunn 1)
        (set! gunls (table))
        (set! lmbp #t))
      (body-lines
        "function init_player(bird)"
        "\tb=0"
        "\tdx1=1"
        "\tdy1=0"
        "\tp = {"
        "\t\tn=1,"
        "\t\tagro = 9999,"
        "\t\tx=-64,y=-64,"
        "\t\tdx=0,dy=0,"
        "\t\ta=0,"
        "\t\t"
        "\t\tspd=.4,"
        "\t\tfric=0.75,"
        "\t\t"
        "\t\tbx=2,by=2,"
        "\t\tbw=4,bh=4,"
        "\t\t"
        "\t\thx=2,hy=2,"
        "\t\thw=4,"
        "\t\t"
        "\t\tlife=10,"
        "\t\tmaxlife=10,"
        "\t\tammo=250,"
        "\t\tmaxammo=250,"
        "\t\t"
        "\t\tspr=bird,"
        "\t\t"
        "\t\tgun=nil,"
        "\t\tgunn=1,"
        "\t\tgunls={},"
        "\t"
        "\t\tlmbp = true,"))
    (def-pico-function #:params () #:returns ()
      (name player_update)
      (params ())
      (returns ())
      (line-range (448 468))
      (api-calls (abs max))
      (called-functions (allbtn))
      (structured-ast
        (if-cond (call allbtn void))
        (if-cond (call allbtn void))
        (if-cond (call allbtn void))
        (if-cond (call allbtn void))
        (if-cond (call abs dx1)))
      (decompiled-pseudo-code
        (set! (-> p :iframes) (call max 0 (- (-> p :iframes) 1)))
        (let ([dx (-> p :dx)] [dy (-> p :dy)] [spd (-> p :spd)]) (when (call allbtn) (-= (-> p :dx) spd)))
        (when (call allbtn) (+= (-> p :dx) spd))
        (when (call allbtn) (-= (-> p :dy) spd))
        (when (call allbtn) (+= (-> p :dy) spd))
        (*= (-> p :dx) (-> p :fric))
        (*= (-> p :dy) (-> p :fric))
        (when (> (+ (call abs dx1) (call abs dy1)) 0.1) (*= dx1 (-> p :fric)) (*= dy1 (-> p :fric))))
      (body-lines
        "function player_update()"
        "\t --damage"
        "\t p.iframes = max(0,p.iframes-1)"
        "\t\t--movement"
        "\t\tlocal dx,dy = p.dx,p.dy"
        "\t\tlocal spd = p.spd"
        "\t\t"
        "\t\tif (allbtn(⬅️)) p.dx-=spd dx1-=spd"
        "\t\tif (allbtn(➡️)) p.dx+=spd dx1+=spd"
        "\t\tif (allbtn(⬆️)) p.dy-=spd dy1-=spd"
        "\t\tif (allbtn(⬇️)) p.dy+=spd dy1+=spd"
        "\t\t"
        "\t\t--58"
        "\t\t"
        "\t\tp.dx *= p.fric"
        "\t\tp.dy *= p.fric"
        "\t\t"
        "  if (abs(dx1)+abs(dy1))>0.1 then"
        "\t\tdx1 *= p.fric"
        "\t\tdy1 *= p.fric"
        "\t\tend"))
    (def-pico-function #:params () #:returns ()
      (name draw_player)
      (params ())
      (returns ())
      (line-range (640 652))
      (api-calls (cos flr line sin))
      (called-functions ())
      (structured-ast
        (if-cond (modulo (-> p :iframes) 5))
        (if-cond (== (-> (-> p :gun) :name) "sniper")))
      (decompiled-pseudo-code
        (when (== (modulo (-> p :iframes) 5) 0) (let ([x (+ (+ (call flr (-> p :x)) (* (call cos (-> p :a)) 6)) 0)] [y (+ (+ (call flr (-> p :y)) (* (call sin (-> p :a)) 3)) 0)]) (when (== (-> (-> p :gun) :name) "sniper") (let ([c (call cos (-> p :a))] [s (call sin (-> p :a))]) (call line void)) (+ (+ x 4) (* c 6)) (+ (+ y 4) (* s 6)) (+ (-> p :x) (* c 128)) (+ (-> p :y) (* s 128))))))
      (body-lines
        "function draw_player()"
        "\tif (p.iframes%5) == 0  then"
        "\t\tlocal x=flr(p.x) + cos(p.a)*6 +0"
        "\t\tlocal y=flr(p.y) + sin(p.a)*3 +0"
        "\t\t"
        "\t\tif p.gun.name==\"sniper\" then"
        "\t\t\tlocal c,s=cos(p.a),sin(p.a)"
        "\t\t\tline("
        "\t\t\tx+4+c*6,"
        "\t\t\ty+4+s*6,"
        "\t\t\tp.x+c*128,"
        "\t\t\tp.y+s*128,8)"
        "\t\tend"))
    (def-pico-function #:params (p) #:returns ()
      (name draw_player_ui)
      (params (p))
      (returns ())
      (line-range (665 691))
      (api-calls (print rectfill spr))
      (called-functions (ospr))
      (structured-ast
        (if-cond (> (-> p :ammo) 0))
        (if-cond (== s "0"))
        (for-loop "i=1,2")
        (if-cond (== i (-> p :gunn))))
      (decompiled-pseudo-code
        (call rectfill (+ camx 1) 1 (+ camx 43) 7 2)
        (let ([l (* 40 (/ (-> p :life) (-> p :maxlife)))]) (call rectfill (+ camx 2) 2 (+ (+ camx 2) l) 6 8))
        (let ([s (string-append "♥" (string-append (-> p :life) (string-append "/" (string-append (-> p :maxlife) " "))))]) (call print s (+ camx 2) 2 7))
        (call rectfill (+ camx 84) 1 (+ (+ camx 84) 42) 7 4)
        (let ([l (* 40 (/ (-> (-> p :gun) :ammo) (-> (-> p :gun) :maxammo)))]) (when (> (-> p :ammo) 0) (call rectfill (+ camx 85) 2 (+ (+ camx 85) l) 6 9)))
        (let ([s (call tostr (-> (-> p :gun) :ammo))] [col 7]) (when (== s "0") (set-values! (s col) ("no ammo!" 14))))
        (call spr 110 (+ camx 89) 2)
        (call print s (+ camx 95) 2 col)
        (for-range i 1 2 (let ((col 1)) (when (== i (-> p :gunn)) (set! col 7))) (call ospr (-> (aref (-> p :gunls) i) :spr) void) (+ (+ camx 90) (* (- i 1) 10))))
      (body-lines
        "function draw_player_ui(p)"
        "\t--life counter"
        "\trectfill(camx+1,1,camx+43,7,2)"
        "\tlocal l=40*(p.life/p.maxlife)"
        "\trectfill(camx+2,2,camx+2+l,6,8)"
        "\t"
        "\tlocal s=\"♥\"..p.life..\"/\"..p.maxlife..\" \""
        "\tprint(s, camx+2,2,7)"
        "\t"
        "\t--ammo bar"
        "\trectfill(camx+84,1,camx+84+42,7,4)"
        "\tlocal l=40*(p.gun.ammo/p.gun.maxammo)"
        "\tif(p.ammo>0)rectfill(camx+85,2,camx+85+l,6,9)"
        "\t"
        "\tlocal s,col = tostr(p.gun.ammo),7"
        "\tif(s==\"0\") s,col=\"no ammo!\",14"
        "\tspr(110,camx+89,2)"
        "\tprint(s, camx+95,2,col)"
        "\t"
        "\t--weapon list"
        "\tfor i=1,2 do"
        "\t\tlocal col = 1"
        "\t\tif(i==p.gunn)col=7"
        "\t\t"
        "\t\tospr(p.gunls[i].spr, "
        "\t\tcamx+90+(i-1)*10, 10,col)"
        "\tend"))
    (def-pico-function #:params (p) #:returns (val)
      (name nextgun)
      (params (p))
      (returns (val))
      (line-range (704 715))
      (api-calls (sfx))
      (called-functions (update_gun))
      (structured-ast
        (if-cond (> (-> p :gunn) (len (-> p :gunls))))
        (for-loop "i=1,#p.gunls")
        (if-cond (== (aref (-> p :gunls) i) (-> p :gunn)))
        (if-cond (+ i (call stat 36)))
        (return-expr (aref (-> p :gunls) (+ (modulo (+ i (call stat 36)) (len (-> p :gunls))) f))))
      (decompiled-pseudo-code
        (call sfx 36)
        (+= (-> p :gunn) 1)
        (when (> (-> p :gunn) (len (-> p :gunls))) (set! (-> p :gunn) 1))
        (call update_gun p)
        (for-range i 1 (len (-> p :gunls)) (when (== (aref (-> p :gunls) i) (-> p :gunn)) (when (< (modulo (+ i (call stat 36)) (len (-> p :gunls))) 1) (set! f (len (-> p :gunls)))) (return (aref (-> p :gunls) (+ (modulo (+ i (call stat 36)) (len (-> p :gunls))) f))))))
      (body-lines
        "function nextgun(p)"
        "\tsfx(36)"
        "\t"
        "\tp.gunn += 1"
        "\tif(p.gunn > #p.gunls) p.gunn = 1"
        "\tupdate_gun(p)"
        "\t--[[local f = 0"
        "\tfor i=1,#p.gunls do"
        "\tif p.gunls[i] == p.gunn then"
        "\t\tif (((i+stat(36))%#p.gunls)<1) f = #p.gunls"
        "\t\t return p.gunls[(i+stat(36))%(#p.gunls)+f]"
        "\t\tend"))
    (def-pico-function #:params (p) #:returns ()
      (name update_gun)
      (params (p))
      (returns ())
      (line-range (719 721))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! (-> p :gun) (aref (-> p :gunls) (-> p :gunn))))
      (body-lines
        "function update_gun(p)"
        "\tp.gun = p.gunls[p.gunn]"
        "end"))
    (def-pico-function #:params (p e) #:returns ()
      (name knockback_player)
      (params (p e))
      (returns ())
      (line-range (723 727))
      (api-calls (abs))
      (called-functions ())
      (structured-ast
        (if-cond (call abs (-> p :dx))))
      (decompiled-pseudo-code
        (when (< (+ (call abs (-> p :dx)) (call abs (-> p :dy))) 3) (+= (-> p :dx) (* (* (-> e :dx) (-> e :spd)) 2)) (+= (-> p :dy) (* (* (-> e :dy) (-> e :spd)) 2))))
      (body-lines
        "function knockback_player(p,e)"
        "\tif abs(p.dx)+abs(p.dy) < 3 then"
        "\t\t\t  p.dx+=e.dx*e.spd*2"
        "\t\t\t\t p.dy+=e.dy*e.spd*2"
        "\t\t\tend\t"))
    (def-pico-function #:params (e b) #:returns ()
      (name knockback_enemy)
      (params (e b))
      (returns ())
      (line-range (730 735))
      (api-calls (abs))
      (called-functions ())
      (structured-ast
        (if-cond (call abs (-> e :dx))))
      (decompiled-pseudo-code
        (when (+ (call abs (-> e :dx)) (call abs (< (-> e :dy) 30))) (+= (-> e :dx) (* (* (-> b :dx) (-> b :spd)) |.|)) (+= (-> e :dy) (* (* (-> b :dy) (-> b :spd)) |.|))))
      (body-lines
        "function knockback_enemy(e,b)"
        "\t"
        "\t\tif (abs(e.dx)+abs(e.dy<30)) then"
        "\t\t\te.dx+=b.dx*b.spd*.1"
        "\t\t\te.dy+=b.dy*b.spd*.1"
        "\t\tend"))
    (def-pico-function #:params (p) #:returns ()
      (name animplayer)
      (params (p))
      (returns ())
      (line-range (739 744))
      (api-calls (flr))
      (called-functions ())
      (structured-ast
        (if-cond (call flr (call time void))))
      (decompiled-pseudo-code
        (if (== (modulo (call flr (* (call time) 7)) 2) 1) (then (set! (-> p :spriteoffset) 1)) (else (set! (-> p :spriteoffset) 0))))
      (body-lines
        "function animplayer(p)"
        "\tif flr(time()*7)%2==1 then"
        "\t\tp.spriteoffset = 1"
        "\telse "
        "\t\tp.spriteoffset = 0"
        "\tend"))
    (def-pico-function #:params (p) #:returns ()
      (name coupdekak)
      (params (p))
      (returns ())
      (line-range (747 752))
      (api-calls (cos flr sin))
      (called-functions ())
      (structured-ast
        (seq-block 6))
      (decompiled-pseudo-code
        (let ([x (+ (+ (call flr (-> p :x)) (* (call cos (-> p :a)) 6)) 0)] [y (+ (+ (call flr (-> p :y)) (* (call sin (-> p :a)) 3)) 0)]) (send (-> p :kak) :fire (+ x 4) (+ y 4) (-> p :a))))
      (body-lines
        "function coupdekak(p)"
        "\tlocal x=flr(p.x) + cos(p.a)*6 +0"
        "\tlocal y=flr(p.y) + sin(p.a)*3 +0"
        "\t"
        "\tp.kak:fire(x+4,y+4,p.a)"
        "end"))
    (def-pico-function #:params (args fire) #:returns ()
      (name make_gun)
      (params (args fire))
      (returns ())
      (line-range (756 790))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond is_enemy))
      (decompiled-pseudo-code
        (set-values! (name_ sprr cd_ spd oa dmg is_enemy auto maxammo sfxx knockback) ((call unpack (call split args))))
        (set! is_enemy (== is_enemy 1))
        (set! auto (== auto 1))
        (when is_enemy (+= dmg (* degaplus 2)))
        (set! gun (table))
        (set! name name_)
        (set! spr sprr)
        (set! spd spd)
        (set! oa oa)
        (set! dmg dmg)
        (set! shake shake)
        (set! auto auto)
        (set! ammo maxammo)
        (set! maxammo maxammo)
        (set! timer 0)
        (set! cooldown cd_)
        (set! is_enemy is_enemy)
        (set-values! (x) (0 y))
        (set! dir 0)
        (set! burst 0)
        (set! sfx sfxx)
        (set! knockback knockback)
        |}|
        (set! (-> gun :fire) fire))
      (body-lines
        "function make_gun(args,fire)"
        "\tlocal name_,sprr,cd_,spd,oa,dmg,is_enemy,auto,maxammo,sfxx,knockback=unpack(split(args))"
        ""
        "\t"
        "\tis_enemy = is_enemy == 1"
        "\tauto = auto  == 1"
        "\tif(is_enemy) dmg += degaplus * 2"
        "\t"
        "\t--todo:not have 3000 args"
        "\tlocal gun = {"
        "\t\tname=name_,"
        "\t\tspr=sprr,"
        "\t\tspd=spd,"
        "\t\toa=oa,--offset angle in [0,1["
        "\t\tdmg=dmg,"
        "\t\tshake=shake,"
        "\t\tauto=auto,"
        "\t\t"
        "\t\tammo=maxammo,"
        "\t\tmaxammo=maxammo,"
        "\t\t"
        "\t\ttimer=0,"
        "\t\tcooldown=cd_,"
        "\t\tis_enemy=is_enemy,"
        "\t\t"
        "\t\tx=0,y=0,"
        "\t\tdir=0,"
        "\t\tburst=0,"
        "\t\t"
        "\t\tsfx=sfxx,"
        "\t\tknockback=knockback,"
        "\t}"))
    (def-pico-function #:params (gun x y dir spd knockback) #:returns ()
      (name shoot)
      (params (gun x y dir spd knockback))
      (returns ())
      (line-range (791 809))
      (api-calls (sfx))
      (called-functions (rrnd))
      (structured-ast
        (if-cond (<= (-> gun :burst) 0))
        (if-cond (-> gun :sfx))
        (if-cond (-> gun :is_enemy))
        (if-cond (== name "kak"))
        (if-cond (== name "boxing glove"))
        (if-cond (== name "flamethrower"))
        (if-cond (== name "explosion"))
        (if-cond (== name "bazooka"))
        (if-cond (not (-> gun :is_enemy)))
        (if-cond (and (< shake 1) (!= name "flamethrower"))))
      (decompiled-pseudo-code
        (when (<= (-> gun :burst) 0) (+= dir (call rrnd (-> gun :oa))))
        (when (-> gun :sfx) (call sfx (-> gun :sfx)))
        (let ([s 93] [name (-> gun :name)] [palette ""]) (when (-> gun :is_enemy) (set! s 95)))
        (when (== name "kak") (set! s 77))
        (when (== name "boxing glove") (set-values! (s lifspa) (77 10)))
        (when (== name "flamethrower") (set! lifspa 40))
        (when (== name "explosion") (set! s 57))
        (when (== name "bazooka") (set! palette "1,2,3,4,5,6,6,8,5,13"))
        (when (not (-> gun :is_enemy)) (when (and (< shake 1) (!= name "flamethrower")) (+= shake 1))))
      (body-lines
        "\tgun.shoot=function(gun,x,y,dir,spd,knockback)"
        "\t\t--remove? it complicates code"
        "\t\tif(gun.burst<=0)dir+=rrnd(gun.oa)"
        "\t\t"
        "\t\tif(gun.sfx) sfx(gun.sfx)"
        "\t\t"
        "\t\tlocal s=93"
        "\t\tlocal name = gun.name"
        "\t\tlocal palette = \"\""
        ""
        "\t\tif(gun.is_enemy)s=95"
        "\t\tif(name==\"kak\")s=77 lifspa=5"
        "\t\tif(name==\"boxing glove\")s,lifspa=77,10"
        "\t\tif(name==\"flamethrower\") lifspa=40 palette=\"1,2,3,4,5,6,10,8,8,9\""
        "\t\tif(name==\"explosion\")s=57 lifspa=10"
        "\t\tif(name==\"bazooka\") palette=\"1,2,3,4,5,6,6,8,5,13\""
        "\t\tif not gun.is_enemy then"
        "\t\t\tif(shake<1 and name!=\"flamethrower\")shake+=1 "
        "\t\tend"))
    (def-pico-function #:params (gun) #:returns ()
      (name update)
      (params (gun))
      (returns ())
      (line-range (820 827))
      (api-calls (max mid))
      (called-functions (shoot))
      (structured-ast
        (if-cond (> (-> gun :burst) 0)))
      (decompiled-pseudo-code
        (set! (-> gun :timer) (call max (- (-> gun :timer) 1) 0))
        (set! (-> gun :ammo) (call mid 0 (-> gun :ammo) (-> gun :maxammo)))
        (when (> (-> gun :burst) 0) (send gun :shoot (-> gun :x) (-> gun :y) (-> gun :dir)) (-= (-> gun :burst) 1)))
      (body-lines
        "\tgun.update=function(gun)"
        "\t\tgun.timer = max(gun.timer-1,0)"
        "\t\tgun.ammo = mid(0,gun.ammo,gun.maxammo)"
        "\t\t"
        "\t\tif gun.burst > 0 then"
        "\t\t\tgun:shoot(gun.x,gun.y,gun.dir)"
        "\t\t\tgun.burst -= 1"
        "\t\tend"))
    (def-pico-function #:params (gun x y dir) #:returns ()
      (name shoot1)
      (params (gun x y dir))
      (returns ())
      (line-range (833 835))
      (api-calls ())
      (called-functions (shoot))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (send gun :shoot x y dir))
      (body-lines
        "function shoot1(gun,x,y,dir)"
        "\tgun:shoot(x,y,dir)"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name initguns)
      (params ())
      (returns ())
      (line-range (852 869))
      (api-calls ())
      (called-functions (make_gun shoot))
      (structured-ast
        (for-loop "i=1,7"))
      (decompiled-pseudo-code
        (set! guns (table))
        (set! revolver (call make_gun "revolver, 64, 15,2.5,.02,3 ,0,       0,   100,    33, 0.3" void))
        shoot1
        |)|
        (set! fireworklauncher (call make_gun "firework launcher, 74, 25,2.5,.02,0.1 ,0,       0,   80,    52, 0.6" void))
        shoot1
        |)|
        (set! boxing_glove (call make_gun "boxing glove, 72, 18,3.3,.005,1 , 0, 0, 1,      53, -0.96" void))
        (call function gun x y dir)
        (for-range i 1 7 (send gun :shoot x y dir)))
      (body-lines
        "function initguns()"
        "guns = {"
        ""
        "                       --name   spr cd spd oa dmg is_enemy auto maxammo sfx"
        "\trevolver = make_gun(\"revolver, 64, 15,2.5,.02,3 ,0,       0,   100,    33, 0.3\","
        "\t\tshoot1"
        "\t),"
        "\t"
        "\t"
        "\tfireworklauncher = make_gun(\"firework launcher, 74, 25,2.5,.02,0.1 ,0,       0,   80,    52, 0.6\","
        "\t\tshoot1"
        "\t),"
        "\t"
        "\tboxing_glove = make_gun(\"boxing glove, 72, 18,3.3,.005,1 , 0, 0, 1,      53, -0.96\","
        " function(gun,x,y,dir)"
        "  for i=1,7 do"
        "\t\t\tgun:shoot(x,y,dir)"
        "\t\tend"))
    (def-pico-function #:params () #:returns (val)
      (name rnd_gun)
      (params ())
      (returns (val))
      (line-range (1011 1016))
      (api-calls (rnd))
      (called-functions ())
      (structured-ast
        (return-expr (call rnd iguns)))
      (decompiled-pseudo-code
        (return (call rnd iguns)))
      (body-lines
        "function rnd_gun()"
        "\t--todo: \"power\" param"
        "\t--later weapons should be  "
        "\t--more powerful"
        "\treturn rnd(iguns)"
        "end"))
    (def-pico-function #:params (x y dir spd r spr dmg is_enemy lifspa palette) #:returns ()
      (name spawn_bullet)
      (params (x y dir spd r spr dmg is_enemy lifspa palette))
      (returns ())
      (line-range (1018 1038))
      (api-calls (add cos sin))
      (called-functions ())
      (structured-ast
        (seq-block 21))
      (decompiled-pseudo-code
        (let ([dx (* (call cos dir) spd)] [dy (* (call sin dir) spd)]) (call add actors (table)))
        (set-values! (x) (x y))
        (set-values! (dx) (dx dy))
        (set! r 4)
        (set! dmg dmg)
        (set! spd spd)
        (set! spr spr)
        (set! is_enemy is_enemy)
        (set! destroy_flag #f)
        (set! dir dir)
        (set! update update_bullet)
        (set! draw draw_bullet)
        (set! lifspa lifspa)
        (set! palette palette)
        |}|)
      (body-lines
        "function spawn_bullet(x,y,dir,spd,r,spr,dmg,is_enemy,lifspa,palette)"
        "\tlocal dx=cos(dir)*spd"
        "\tlocal dy=sin(dir)*spd"
        "\tadd(actors,{"
        "\t\tx=x,  y=y,"
        "\t\tdx=dx,dy=dy,"
        "\t\tr=4,"
        "\t\tdmg=dmg,"
        "\t\tspd=spd,"
        "\t\tspr=spr,"
        "\t\tis_enemy=is_enemy,"
        "\t\tdestroy_flag=false,"
        "\t\tdir=dir,"
        "\t\t"
        "\t\tupdate=update_bullet,"
        "\t\tdraw=draw_bullet,"
        "\t\tlifspa=lifspa,"
        ""
        "\t\tpalette=palette,"
        "\t})"
        "end"))
    (def-pico-function #:params (b) #:returns ()
      (name update_bullet)
      (params (b))
      (returns ())
      (line-range (1040 1044))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond (not (== (-> b :lifspa) nil)))
        (if-cond (== (-> b :lifspa) 0)))
      (decompiled-pseudo-code
        if
        (-= (-> b :lifspa) 1)
        (when (== (-> b :lifspa) 0) (set! (-> b :destroy_flag) #t)))
      (body-lines
        "function update_bullet(b)"
        " if not(b.lifspa== nil)then"
        "  b.lifspa-=1"
        "  if (b.lifspa== 0) b.destroy_flag = true"
        " end"))
    (def-pico-function #:params (b) #:returns ()
      (name draw_bullet)
      (params (b))
      (returns ())
      (line-range (1145 1149))
      (api-calls (pal spr))
      (called-functions ())
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (call pal (call split (-> b :palette)))
        (call spr (-> b :spr) (- (-> b :x) 4) (- (-> b :y) 4) 1 1 (-> p :flip))
        (call pal))
      (body-lines
        "function draw_bullet(b)"
        "\tpal(split(b.palette))"
        "\tspr(b.spr, b.x-4, b.y-4,1,1, p.flip)"
        "\tpal()"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name draw_random)
      (params ())
      (returns ())
      (line-range (1151 1154))
      (api-calls (all spr))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        for
        (call spr (-> i :spr) (- (-> i :x) 4) (- (-> i :y) 4) 1 1 (-> i :f) (-> i :r)))
      (body-lines
        "function draw_random()"
        "for i in all(random)do"
        "\t spr(i.spr, i.x-4, i.y-4,1,1,i.f,i.r)"
        "\tend"))
    (def-pico-function #:params (e) #:returns ()
      (name killbarelle)
      (params (e))
      (returns ())
      (line-range (1157 1161))
      (api-calls (del))
      (called-functions (animexplo))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (call animexplo e)
        (send (-> e :gun) :fire (+ (-> e :x) 4) (+ (-> e :y) 4) (-> e :a))
        (call del enemies e))
      (body-lines
        "function killbarelle(e)"
        " animexplo(e)"
        "\te.gun:fire(e.x+4,e.y+4,e.a)"
        "\tdel(enemies,e)"
        "end"))
    (def-pico-function #:params (e) #:returns ()
      (name animexplo)
      (params (e))
      (returns ())
      (line-range (1163 1169))
      (api-calls (rnd))
      (called-functions (make_ptc rrnd))
      (structured-ast
        (for-loop "i=1,15"))
      (decompiled-pseudo-code
        (for-range i 1 15 (call make_ptc void) (+ (-> e :x) (call rrnd 14)) (+ (-> e :y) (call rrnd 14)) (+ 8 (call rnd 8))))
      (body-lines
        "function animexplo(e)"
        "for i=1,15 do"
        "\t\tmake_ptc("
        "\t\t\t\t\te.x + rrnd(14),"
        "\t\t\t\t\te.y + rrnd(14),"
        "\t\t\t8+rnd(8),rnd{9,10})"
        "\tend"))
    (def-pico-function #:params (x y type_bullet speed timer_bullet1 sprite nb_bullet ecartement) #:returns ()
      (name spawn_bullet)
      (params (x y type_bullet speed timer_bullet1 sprite nb_bullet ecartement))
      (returns ())
      (line-range (1177 1194))
      (api-calls ())
      (called-functions (get_traj rafale))
      (structured-ast
        (if-cond (== timer_bullet 0))
        (if-cond (== type_bullet 1)))
      (decompiled-pseudo-code
        (when (== timer_bullet 0) (let ([xy (call get_traj x y mouse_x mouse_y)] [traj_x (* (-> xy :x) speed)] [traj_y (* (-> xy :y) speed)] [angle (-> xy :angle)]) (set! timer_bullet timer_bullet1)) (when (== type_bullet 1) (set! nvelement (table)) (set-values! (x) (x y)) (set! type_bullet type_bullet) (set! traj_x traj_x) (set! traj_y traj_y) (set! sprite sprite) |}| (call rafale 10 nvelement))))
      (body-lines
        "function spawn_bullet(x,y,type_bullet,speed,timer_bullet1,sprite,nb_bullet,ecartement)"
        "\tif timer_bullet == 0 then"
        "\t\tlocal xy = get_traj(x,y,mouse_x,mouse_y)"
        "\t\tlocal traj_x = xy.x*speed"
        "\t\tlocal traj_y = xy.y*speed"
        "\t\tlocal angle = xy.angle"
        "\t\ttimer_bullet = timer_bullet1"
        "\t\t"
        "\t\tif type_bullet == 1 then"
        "\t\t\tnvelement = {"
        "\t\t\t  x=x,y=y,"
        "\t\t\t  type_bullet=type_bullet,"
        "\t\t\t  traj_x=traj_x,"
        "\t\t\t  traj_y=traj_y,"
        "\t\t\t  sprite=sprite"
        "\t\t\t}"
        "\t\t\trafale(10,nvelement)"
        "\t\tend"))
    (def-pico-function #:params () #:returns ()
      (name update_bullet)
      (params ())
      (returns ())
      (line-range (1221 1226))
      (api-calls (all del))
      (called-functions (is_solid))
      (structured-ast
        (if-cond (> timer_bullet 0))
        (for-loop "i in all(bullet)")
        (if-cond (call is_solid (+ (-> i :x) (* (-> i :traj_x) 1.5)))))
      (decompiled-pseudo-code
        (when (> timer_bullet 0) (-= timer_bullet 1))
        (foreach i bullet (when (call is_solid (+ (+ (-> i :x) (* (-> i :traj_x) 1.5)) 4) (+ (+ (-> i :y) 4) (* (-> i :traj_y) 1.5))) (call del bullet i))))
      (body-lines
        "function update_bullet()"
        " if (timer_bullet>0)timer_bullet-=1"
        "\tfor i in all(bullet) do"
        "\t\tif is_solid(i.x+(i.traj_x*1.5)+4,i.y+4+(i.traj_y*1.5)) then"
        "\t\t del(bullet,i)"
        "\t end"))
    (def-pico-function #:params () #:returns ()
      (name draw_bullet)
      (params ())
      (returns ())
      (line-range (1232 1235))
      (api-calls (all spr))
      (called-functions ())
      (structured-ast
        (for-loop "i in all(bullet)"))
      (decompiled-pseudo-code
        (foreach i bullet (call spr (-> i :sprite) (-> i :x) (-> i :y))))
      (body-lines
        "function draw_bullet()"
        "\tfor i in all(bullet) do"
        "\t\tspr(i.sprite,i.x,i.y)"
        "\tend"))
    (def-pico-function #:params (nb bullet) #:returns ()
      (name rafale)
      (params (nb bullet))
      (returns ())
      (line-range (1238 1240))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (call add rafalels (table (:nb nb) (:bullet bullet))))
      (body-lines
        "function rafale(nb,bullet)"
        " add(rafalels,{nb=nb,bullet=bullet})"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name updaterafale)
      (params ())
      (returns ())
      (line-range (1242 1247))
      (api-calls (add all del))
      (called-functions ())
      (structured-ast
        (for-loop "i in all(rafalels)")
        (if-cond (< (-> i :nb) 1)))
      (decompiled-pseudo-code
        (foreach i rafalels (when (< (-> i :nb) 1) (call del rafalels i)) (call add bullet (-> i :bullet)) (-= (-> i :nb) 1)))
      (body-lines
        "function updaterafale()\t"
        "\tfor i in all(rafalels) do"
        "  if (i.nb<1) del(rafalels,i)"
        "  add(bullet,i.bullet)"
        "  i.nb -=1"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name mouse_x_y)
      (params ())
      (returns ())
      (line-range (1252 1259))
      (api-calls (flr poke))
      (called-functions ())
      (structured-ast
        (seq-block 8))
      (decompiled-pseudo-code
        (call poke 24365 1)
        (set! mx (+ (call stat 32) (call flr camx)))
        (set! my (call stat 33))
        (let ([s (call stat 34)]) (set! lmb s))
        (set! rmb s))
      (body-lines
        "function mouse_x_y()"
        "\tpoke(0x5f2d, 1)"
        "\tmx=stat(32)+flr(camx)"
        "\tmy=stat(33)"
        "\tlocal s = stat(34)"
        "\tlmb=s&1 > 0"
        "\trmb=s&2 > 0"
        "end"))
    (def-pico-function #:params (x_satr y_start x_end y_end) #:returns (val)
      (name get_traj)
      (params (x_satr y_start x_end y_end))
      (returns (val))
      (line-range (1264 1270))
      (api-calls (atan2 cos sin))
      (called-functions ())
      (structured-ast
        (return-expr (table (:x (call cos angle)))))
      (decompiled-pseudo-code
        (set! angle (call atan2 (- (- x_end x_satr) 4) void))
        (- (- y_end y_start) 4)
        (return (table (:x (call cos angle))))
        (set-values! (y) ((call sin angle) angle))
        end)
      (body-lines
        "--[[function get_traj(x_satr,y_start,x_end,y_end)"
        "\tangle=atan2(x_end-x_satr-4, "
        "\t y_end-y_start-4)"
        "\treturn {x=cos(angle),"
        "\t y=sin(angle),angle=angle}"
        "end]]"
        ""))
    (def-pico-function #:params (flag x y) #:returns (val)
      (name check_flag)
      (params (flag x y))
      (returns (val))
      (line-range (1271 1273))
      (api-calls (fget mget))
      (called-functions ())
      (structured-ast
        (return-expr (call fget (call mget x))))
      (decompiled-pseudo-code
        (return (call fget (call mget x))))
      (body-lines
        "function check_flag(flag,x,y)"
        "\treturn fget(mget((x\\8),(y\\8)),flag)"
        "end"))
    (def-pico-function #:params (x y) #:returns (val)
      (name is_solid)
      (params (x y))
      (returns (val))
      (line-range (1277 1280))
      (api-calls ())
      (called-functions (check_flag))
      (structured-ast
        (if-cond (< x 0))
        (return-expr #t)
        (return-expr (call check_flag 0 x y)))
      (decompiled-pseudo-code
        (when (< x 0) (return #t))
        (return (call check_flag 0 x y)))
      (body-lines
        "function is_solid(x,y)"
        "\tif(x<0)return true "
        "\treturn check_flag(0,x,y)"
        "end"))
    (def-pico-function #:params (x y x1 y1 x2 y2) #:returns (val)
      (name touches_rect)
      (params (x y x1 y1 x2 y2))
      (returns (val))
      (line-range (1282 1287))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr (<= x1 x)))
      (decompiled-pseudo-code
        (return (<= x1 x))
        and
        and
        and)
      (body-lines
        "function touches_rect(x,y,x1,y1,x2,y2)"
        "\treturn x1 <= x"
        "\t   and x2 >= x"
        "\t   and y1 <= y"
        "\t   and y2 >= y"
        "end"))
    (def-pico-function #:params (a b) #:returns (val)
      (name circ_coll)
      (params (a b))
      (returns (val))
      (line-range (1289 1300))
      (api-calls (max))
      (called-functions ())
      (structured-ast
        (return-expr (< (+ (* dx dx) (* dy dy)) (* sr sr))))
      (decompiled-pseudo-code
        (let ([dx (- (+ (-> a :x) 4) (-> b :x))] [dy (- (+ (-> a :y) 4) (-> b :y))] [d (call max dx dy)]) (/= dx d))
        (/= dy d)
        (let ([sr (/ (+ (-> a :r) (-> b :r)) d)]) (return (< (+ (* dx dx) (* dy dy)) (* sr sr)))))
      (body-lines
        "function circ_coll(a,b)"
        "\t--https://www.lexaloffle.com/bbs/?tid=28999"
        "\t--b: bullet"
        "\tlocal dx=a.x+4 - b.x"
        "\tlocal dy=a.y+4 - b.y"
        "\tlocal d = max(dx,dy)"
        "\tdx /= d"
        "\tdy /= d"
        "\tlocal sr = (a.r+b.r)/d"
        "\t"
        "\treturn dx*dx+dy*dy < sr*sr "
        "end"))
    (def-pico-function #:params (a1 a2 b1 b2) #:returns (val)
      (name rect_overlap)
      (params (a1 a2 b1 b2))
      (returns (val))
      (line-range (1303 1313))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr (not (> (-> a1 :x) (-> b2 :x))))
        (return-expr (< (-> a1 :x) (-> b2 :x))))
      (decompiled-pseudo-code
        or
        or
        or
        (return (< (-> a1 :x) (-> b2 :x)))
        and
        and
        and)
      (body-lines
        "function rect_overlap(a1,a2,b1,b2)"
        "\t--[[return not (a1.x>b2.x"
        "\t         or a1.y>b2.y "
        "\t         or a2.x<b1.x"
        "\t         or a2.y<b1.y)--]]"
        "\t"
        "\treturn a1.x<b2.x"
        "\t   and a1.y<b2.y "
        "\t   and a2.x>b1.x"
        "\t   and a2.y>b1.y--]]"
        "end"))
    (def-pico-function #:params (x y w h flag) #:returns ()
      (name collision)
      (params (x y w h flag))
      (returns ())
      (line-range (1315 1321))
      (api-calls ())
      (called-functions (is_solid))
      (structured-ast
        (return-expr void))
      (decompiled-pseudo-code
        (return)
        (call is_solid x y)
        or
        or
        or)
      (body-lines
        "function collision(x,y,w,h,flag)"
        "\treturn "
        "\t   is_solid(x,  y)"
        "\tor is_solid(x+w,y)"
        "\tor is_solid(x,  y+h)"
        "\tor is_solid(x+w,y+h) "
        "end"))
    (def-pico-function #:params (o bounce1) #:returns ()
      (name collide)
      (params (o bounce1))
      (returns ())
      (line-range (1323 1341))
      (api-calls ())
      (called-functions (collision))
      (structured-ast
        (if-cond coll_x))
      (decompiled-pseudo-code
        (let ([x (-> o :x)] [y (-> o :y)] [dx (-> o :dx)] [dy (-> o :dy)] [w (-> o :bw)] [h (-> o :bh)] [ox (+ x (-> o :bx))] [oy (+ y (-> o :by))] [bounce bounce1] [we (- w 1)] [he (- h 1)] [coll_x (call collision void)]) (+ ox dx))
        (set! coll_y (call collision void))
        ox
        (set! coll_xy (call collision void))
        (+ ox dx)
        (when coll_x (*= (-> o :dx) (- bounce))))
      (body-lines
        "function collide(o,bounce1)"
        "\tlocal x,y = o.x,o.y"
        "\tlocal dx,dy = o.dx,o.dy"
        "\tlocal w,h = o.bw,o.bh"
        "\tlocal ox,oy = x+o.bx,y+o.by"
        "\tlocal bounce = bounce1"
        "\t"
        "\t--collisions"
        "\tlocal we,he = w-1, h-1"
        "\tlocal coll_x = collision( "
        "\tox+dx, oy,    we, he)"
        "\tlocal coll_y = collision("
        "\tox,    oy+dy, we, he)"
        "\tlocal coll_xy = collision("
        "\tox+dx, oy+dy, we, he)"
        "\t"
        "\tif coll_x then"
        "\t\to.dx *= -bounce"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name gen_train)
      (params ())
      (returns ())
      (line-range (1359 1364))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (for-loop "i=10,29"))
      (decompiled-pseudo-code
        (set! nums (table))
        (for-range i 10 29 (call add nums i)))
      (body-lines
        "function gen_train()"
        "\t--gen talbe of all wagon nums"
        "\tnums = {}"
        "\tfor i=10,29 do"
        "\t\tadd(nums,i)"
        "\tend"))
    (def-pico-function #:params (a b) #:returns ()
      (name clone_room)
      (params (a b))
      (returns ())
      (line-range (1390 1398))
      (api-calls (mget mset))
      (called-functions ())
      (structured-ast
        (for-loop "j = 0,15")
        (for-loop "i = 0,15"))
      (decompiled-pseudo-code
        (let ([ax (* (modulo a 8) 16)] [ay a]) (set! room_all (table)))
        (for-range j 0 15 (for-range i 0 15 (let ((t (call mget (+ ax i) (+ ay j)))) (call mset (+ (* b 16) i) j t)))))
      (body-lines
        "function clone_room(a,b)"
        "\tlocal ax = (a%8)*16"
        "\tlocal ay = (a\\8)*16"
        "\troom_all= {}"
        "\tfor j = 0,15 do"
        "\t\tfor i = 0,15 do"
        "\t\t\tlocal t=mget(ax+i,ay+j)"
        "\t\t\tmset(b*16+i,j,t)"
        "\t\tend"))
    (def-pico-function #:params () #:returns ()
      (name update_door)
      (params ())
      (returns ())
      (line-range (1402 1423))
      (api-calls (rnd sfx))
      (called-functions (copy make_drop make_ptc rnd_gun rrnd))
      (structured-ast
        (for-loop "i=1,5"))
      (decompiled-pseudo-code
        (set! wl wl)
        if
        (not enemiescleared)
        (call sfx 37)
        (call sfx 42)
        (let ([x (* (- wl 1) 16)] [g (call rnd_gun)]) (call make_drop (+ (* x 8) 60) 56 (-> g :spr) "gun" void))
        (call copy g)
        (set! enemiescleared #t)
        (for-range i 1 5 (call make_ptc void) (+ (* x 8) (call rrnd 8)) (+ 56 (call rrnd 8)) (+ 8 (call rnd 8))))
      (body-lines
        "function update_door()"
        "\tlocal wl = wl"
        "\t--unlock next wagon"
        "\tif #enemies <= 0 and "
        "\tnot enemiescleared then"
        "\t\t"
        "\t\tsfx(37)"
        "\t\tsfx(42)"
        "\t\t"
        "\t\tlocal x=(wl-1)*16"
        "\t\tlocal g=rnd_gun()"
        "\t\t"
        "\t\tmake_drop(x*8+60,56,g.spr,\"gun\","
        "\t\tcopy(g))"
        "\t\tenemiescleared=true"
        "\t\t"
        "\t\tfor i=1,5 do"
        "\t\t\tmake_ptc("
        "\t\t\t  x*8 + rrnd(8),"
        "\t\t\t  56  + rrnd(8),"
        "\t\t\t8+rnd(8),rnd{9,10})"
        "\t\tend"))
    (def-pico-function #:params (x) #:returns ()
      (name init_boss_room)
      (params (x))
      (returns ())
      (line-range (1437 1441))
      (api-calls (mset))
      (called-functions ())
      (structured-ast
        (for-loop "i=5,9"))
      (decompiled-pseudo-code
        (call mset x 4 40)
        (for-range i 5 9 (call mset x i 39)))
      (body-lines
        "function init_boss_room(x)"
        "\tmset(x,4,40)"
        "\tfor i=5,9 do"
        "\t\tmset(x,i,39)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name begin_boss)
      (params ())
      (returns ())
      (line-range (1445 1454))
      (api-calls (mset))
      (called-functions (burst_ptc spawn_enemy))
      (structured-ast
        (for-loop "i=5,9"))
      (decompiled-pseudo-code
        (let ([x (* (- wl 1) 16)]) (call spawn_enemy (+ (* x 8) (* 8 12)) void))
        56
        (call mset x i 6)
        (for-range i 5 9 (call mset x i 6) (call burst_ptc (* x 8) (* i 8) 10)))
      (body-lines
        "function begin_boss()"
        "\tlocal x = (wl-1)*16"
        "\tspawn_enemy(x*8+8*12,"
        "\t56,enemy.boss)"
        "\t"
        "\tmset(x,i,6)"
        "\tfor i=5,9 do"
        "\t\tmset(x,i,6)"
        "\t\tburst_ptc(x*8,i*8,10)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name update_room)
      (params ())
      (returns ())
      (line-range (1458 1464))
      (api-calls ())
      (called-functions (clone_room))
      (structured-ast
        (for-loop "i=0,3"))
      (decompiled-pseudo-code
        (for-range i 0 3 (let ((w (+ (* wagon_n wl) i))) (call clone_room (aref train w) i))))
      (body-lines
        "function update_room()"
        "\tfor i=0,3 do"
        "\t\tlocal w=wagon_n*wl + i"
        "\t\t"
        "\t\t--printh(\"train[\"..tostr(w)..\"]:\"..tostr(train[w]))"
        "\t\tclone_room(train[w],i)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name draw_map)
      (params ())
      (returns ())
      (line-range (1468 1485))
      (api-calls (map min pal palt))
      (called-functions (draw_ghost_connector draw_random))
      (structured-ast
        (if-cond (> pal_n (len trainpal))))
      (decompiled-pseudo-code
        (set! pal_n (call min 7 pal_n))
        (call pal 8 (aref trainpal (- (* pal_n 2) 1)))
        (call pal 14 (aref trainpal (* pal_n 2)))
        (call draw_ghost_connector)
        (call map)
        (call draw_random)
        (call palt)
        (call pal))
      (body-lines
        "function draw_map()"
        "\t-- wall palette"
        "--\tif(pal_n>#trainpal) pal_n=1"
        "--\tpal(8,trainpal[pal_n][1])"
        "--\tpal(14,trainpal[pal_n][2])"
        ""
        " -- zep:"
        " pal_n=min(7,pal_n)"
        " pal(8,trainpal[pal_n*2-1])"
        " pal(14,trainpal[pal_n*2])"
        "\t"
        "\tdraw_ghost_connector()"
        "\tmap()"
        "\tdraw_random()"
        "\t"
        "\tpalt()"
        "\tpal()"
        "end"))
    (def-pico-function #:params (x y) #:returns ()
      (name break_crate)
      (params (x y))
      (returns ())
      (line-range (1487 1491))
      (api-calls ())
      (called-functions (spawn_loot))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (call spawn_loot x))
      (body-lines
        "function break_crate(x,y)"
        "\t--spawn_loot(x\\8*8,y\\8*8)"
        "\tspawn_loot(x&~7,y&~7) -- zep"
        "\t"
        "end"))
    (def-pico-function #:params (x y) #:returns ()
      (name swichtile)
      (params (x y))
      (returns ())
      (line-range (1495 1498))
      (api-calls (mget mset))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! t (call mget x))
        (call mset x))
      (body-lines
        "function swichtile(x,y)"
        " local t = mget((x\\8),(y\\8))"
        " mset((x\\8),(y\\8),t+1)"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name parcourmap)
      (params ())
      (returns ())
      (line-range (1500 1511))
      (api-calls (mget mset rnd))
      (called-functions (spawn_enemy))
      (structured-ast
        (if-cond (== wagon_n 0))
        (for-loop "x=x1,16*(wl-1)")
        (for-loop "y=2,12")
        (if-cond (or (or (> x 3) (> (- (-> p :y) 1000) (* y 8))) (< (+ (-> p :y) 1000) (* y 8))))
        (if-cond (call mget x y))
        (if-cond (call rnd 4)))
      (decompiled-pseudo-code
        (let ([x1 0]) (when (== wagon_n 0) (set! x1 16)))
        (for-range x x1 (* 16 (- wl 1)) (for-range y 2 12 (when (or (or (> x 3) (> (- (-> p :y) 1000) (* y 8))) (< (+ (-> p :y) 1000) (* y 8))) (when (== (call mget x y) 109) (call mset x y 39) (when (> (call rnd 4) 3) (call spawn_enemy (* x 8) (* y 8) (-> enemy :explosive_barrel))))))))
      (body-lines
        "function parcourmap()"
        ""
        " local x1=0"
        " if(wagon_n==0)x1=16"
        " \tfor x=x1,16*(wl-1) do"
        "  \tfor y=2,12 do"
        "   \tif x>3 or p.y-1000>y*8 or p.y+1000<y*8 then"
        "    \tif mget(x,y)==109 then"
        "   \t  mset(x,y,39)"
        "   \t  if rnd(4)>3 then"
        "   \t  spawn_enemy(x * 8,y * 8,enemy.explosive_barrel)"
        "   \t  end"))
    (def-pico-function #:params (x y) #:returns ()
      (name sapwnrndenemy)
      (params (x y))
      (returns ())
      (line-range (1521 1533))
      (api-calls (ceil rnd))
      (called-functions (spawn_enemy))
      (structured-ast
        (if-cond (call ceil (call rnd 25)))
        (for-loop "i=0,ceil(rnd(wagon_n/2))+8"))
      (decompiled-pseudo-code
        (when (== (call ceil (call rnd 25)) 10) (call spawn_enemy (* x 8) (* y 8) (-> enemy :explosive_barrel)) (when (and (> (call ceil (call rnd 32)) (- 31 (* wagon_n 0.7))) (> wagon_n 1)) (call spawn_enemy (* x 8) (* y 8) (-> enemy :juggernaut)) (when (and (> (call ceil (call rnd 30)) (- 28.5 (* wagon_n 0.5))) (> wagon_n 0)) (for-range i 0 (+ (call ceil (call rnd (/ wagon_n 2))) 8) (call spawn_enemy (* x 8) (* y 8) (-> enemy :warm)))))))
      (body-lines
        "function sapwnrndenemy(x,y)"
        "\t--spawn explosive_barrel "
        "      if ceil(rnd(25))==10 then"
        "      spawn_enemy(x * 8,y * 8,enemy.explosive_barrel)"
        "     --spawn juggernaut"
        "     elseif ceil(rnd(32))>31-(wagon_n*0.7) and wagon_n>1 then"
        "      spawn_enemy(x * 8,y * 8,enemy.juggernaut)"
        "     "
        "     --spawn warm"
        "     elseif ceil(rnd(30))>28.5-(wagon_n*0.5) and wagon_n>0 then"
        "      for i=0,ceil(rnd(wagon_n/2))+8 do"
        "      spawn_enemy(x * 8,y * 8,enemy.warm)"
        "      end"))
    (def-pico-function #:params () #:returns ()
      (name init_enemies)
      (params ())
      (returns ())
      (line-range (1582 1648))
      (api-calls ())
      (called-functions (make_enemy))
      (structured-ast
        (seq-block 67))
      (decompiled-pseudo-code
        (set! enemy (table))
        (set! hedgehog (call make_enemy void))
        x
        (-> guns :gunslime)
        (set! hedgehogbuff (call make_enemy void))
        x
        (-> guns :gunslimebuff)
        (set! juggernaut (call make_enemy void))
        x
        #t
        (-> guns :shotgunmechant)
        (set! warm (call make_enemy void))
        x
        #t
        (-> guns :null)
        (set! tourelle (call make_enemy void))
        x
        (-> guns :machinegunmechant)
        (set! explosive_barrel (call make_enemy void))
        x
        (-> guns :explosion)
        (set! boss (call make_enemy void))
        x
        #t)
      (body-lines
        "function init_enemies()"
        "\tenemy= {"
        "\t"
        "\thedgehog=make_enemy("
        "--x,y,sprite,speed,life,shootrange,  "
        "\t x,y,108   ,1    ,5   ,7.75   ,"
        "--chase,seerange"
        "\t false,1,"
        "\t guns.gunslime),"
        "\t "
        "\thedgehogbuff=make_enemy("
        "--x,y,sprite,speed,life,shootrange,  "
        "\t x,y,92   ,1    ,10   ,7.75   ,"
        "--chase,seerange"
        "\t false,1,"
        "\t guns.gunslimebuff),"
        "\t "
        "\t "
        "  juggernaut=make_enemy("
        "--x,y,sprite,speed,life,shootrange,  "
        "\t x,y,94    ,1.5  ,30  ,3   ,  "
        "--chase,seerange"
        "  true,8, "
        "\t guns.shotgunmechant),"
        "\t "
        "\t warm=make_enemy("
        "--x,y,sprite,speed,life,shootrange,  "
        "\t x,y,126    ,1  ,1  ,0   ,  "
        "--chase,seerange"
        "  true,6.5, "
        "\t guns.null),"
        "\t "))
    (def-pico-function #:params (x y name) #:returns ()
      (name spawn_enemy)
      (params (x y name))
      (returns ())
      (line-range (1650 1663))
      (api-calls (rnd))
      (called-functions (copy))
      (structured-ast
        (if-cond (== (-> a :spr) 1))
        (if-cond (!= (-> a :spr) 125))
        (if-cond (== (-> a :spr) 126))
        (if-cond (< (-> a :x) 175)))
      (decompiled-pseudo-code
        (let ([a (call copy name)]) (set! (-> a :x) x))
        (set! (-> a :y) y)
        (set! (-> a :gun) (call copy (-> a :gun)))
        (let ([r (call rnd 60)]) (when (== (-> a :spr) 1) (set! r 0)))
        (when (!= (-> a :spr) 125) (+= (-> (-> a :gun) :cooldown) r))
        (when (== (-> a :spr) 126) (set! (-> a :spd) (+ 0.8 (call rnd 0.4))))
        (when (< (-> a :x) 175) (+= (-> (-> a :gun) :timer) 90) (set! (-> a :timer) 90)))
      (body-lines
        "function spawn_enemy(x,y,name)"
        "\tlocal a=copy(name)"
        "\ta.x = x"
        "\ta.y = y"
        "\ta.gun = copy(a.gun)"
        "\tlocal r = rnd(60)"
        "\tif(a.spr==1)r = 0"
        "\tif (a.spr != 125)a.gun.cooldown += r"
        "\t"
        " if (a.spr == 126)a.spd = 0.8+rnd(0.4)"
        " if a.x<175 then"
        "  a.gun.timer += 90"
        "  a.timer = 90"
        " end"))
    (def-pico-function #:params (e) #:returns ()
      (name update_enemy)
      (params (e))
      (returns ())
      (line-range (1668 1680))
      (api-calls (all max))
      (called-functions (canshoot loaded))
      (structured-ast
        (for-loop "i in all(enemies)")
        (if-cond (call loaded i)))
      (decompiled-pseudo-code
        (foreach i enemies (when (call loaded i) (set! mouvrnd #t) (set! (-> (-> i :gun) :timer) (call max (- (-> (-> i :gun) :timer) 1))) |,| if (or (call canshoot i p) (== (-> i :spr) 1)) (send (-> i :gun) :fire (+ (-> i :x) 4) (+ (-> i :y) 4) (-> i :a)))))
      (body-lines
        "function update_enemy(e)"
        "\tfor i in all(enemies) do"
        "\t\tif loaded(i) then"
        "\t\t\tmouvrnd = true"
        "\t\t\t"
        "\t\t\ti.gun.timer = max(i.gun.timer-1--/#enemies"
        "\t\t\t,0)"
        "\t\t\t"
        "\t\t\tif i.gun.timer<=0 and "
        "\t\t\t(canshoot(i,p) or i.spr==1)then"
        "\t\t\t\t"
        "\t\t\t\ti.gun:fire(i.x+4,i.y+4,i.a)"
        "\t\t\tend"))
    (def-pico-function #:params (e) #:returns ()
      (name draw_enemy)
      (params (e))
      (returns ())
      (line-range (1699 1722))
      (api-calls (ceil cos flr print rectfill sin spr))
      (called-functions ())
      (structured-ast
        (if-cond (== (-> e :spr) 1))
        (if-cond (== (-> e :spr) 1)))
      (decompiled-pseudo-code
        (let ([w 1]) (when (== (-> e :spr) 1) (set! w 2)))
        (set! x (+ (call flr (-> e :x)) void))
        (* (* (call cos (-> e :pangle)) 6) w)
        (set! y (+ (call flr (-> e :y)) void))
        (* (* (call sin (-> e :pangle)) 3) w)
        (call spr (-> (-> e :gun) :spr) x y 1 1 (-> e :flip))
        (call spr (-> e :spr) (-> e :x) (-> e :y) w w (-> e :flip))
        (when (== (-> e :spr) 1) (call rectfill (+ camx 1) 120 void) (+ camx 126) (let ([l (* 126 (/ (-> e :life) 300))]) (call rectfill (+ camx 2) 121 (+ (+ camx 2) l) void)) 125 (let ([s (string-append "🐱" (string-append (call ceil (-> e :life)) (string-append "/" "300")))]) (call print s (+ camx 3) 121 7))))
      (body-lines
        "function draw_enemy(e)"
        "\tlocal w = 1"
        "\tif(e.spr==1)w=2"
        "\t"
        "\tlocal x=flr(e.x)+"
        "\tcos(e.pangle)*6*w"
        "\tlocal y=flr(e.y)+"
        "\tsin(e.pangle)*3*w"
        "\t"
        "\tspr(e.gun.spr,x,y,1,1, e.flip)"
        "\t"
        "\tspr(e.spr,e.x,e.y,w,w, e.flip)"
        "\t"
        "\t--boss health bar"
        "\tif e.spr==1 then"
        "\t\trectfill(camx+1,120,"
        "\t\tcamx+126,126,4)"
        "\t\tlocal l=126*(e.life/300)"
        "\t\trectfill(camx+2,121,camx+2+l,"
        "\t\t125,9)"
        "\t\t"
        "\t\tlocal s=\"🐱\"..ceil(e.life)..\"/\"..\"300\""
        "\t\tprint(s, camx+3,121,7)"
        "\tend"))
    (def-pico-function #:params (i) #:returns ()
      (name update_boss)
      (params (i))
      (returns ())
      (line-range (1730 1738))
      (api-calls (rnd))
      (called-functions ())
      (structured-ast
        (if-cond (< (-> i :phasetimer) 0)))
      (decompiled-pseudo-code
        (-= (-> i :phasetimer) 1)
        (-= (-> i :pause) 1)
        (when (< (-> i :phasetimer) 0) (set! (-> i :phasetimer) (+ 600 (call rnd 600))) (+= (-> i :phase) 1) (set! (-> i :pause) 200)))
      (body-lines
        "function update_boss(i)"
        "\ti.phasetimer -= 1"
        "\ti.pause -= 1"
        "\t"
        "\tif i.phasetimer<0 then"
        "\t\ti.phasetimer=600+rnd(600)"
        "\t\ti.phase+=1"
        "\t\ti.pause = 200"
        "\tend"))
    (def-pico-function #:params (i) #:returns ()
      (name changedirection)
      (params (i))
      (returns ())
      (line-range (1745 1752))
      (api-calls (cos sin))
      (called-functions (rrnd))
      (structured-ast
        (if-cond (< (-> i :timer) 1)))
      (decompiled-pseudo-code
        (-= (-> i :timer) 1)
        (when (< (-> i :timer) 1) (+= (-> i :angle) (call rrnd 0.25)) (set! (-> i :timer) (-> i :cd)) (set! (-> i :dx) (* (/ (call cos (-> i :angle)) 8) (-> i :spd))) (set! (-> i :dy) (* (/ (call sin (-> i :angle)) 8) (-> i :spd)))))
      (body-lines
        "function changedirection(i)"
        "\ti.timer-=1"
        "\tif i.timer < 1 then"
        "\t i.angle += rrnd(0.25)"
        "\t i.timer=i.cd"
        "\t i.dx=cos(i.angle)/8*i.spd "
        "\t i.dy=sin(i.angle)/8*i.spd"
        "\tend"))
    (def-pico-function #:params (e pl) #:returns (val)
      (name canshoot)
      (params (e pl))
      (returns (val))
      (line-range (1755 1773))
      (api-calls (abs atan2 cos max sin))
      (called-functions (cansee dist))
      (structured-ast
        (if-cond (call abs dist))
        (return-expr (call cansee e angle x y dist)))
      (decompiled-pseudo-code
        (set! angle (call atan2 (- (-> pl :x) (-> e :x)) void))
        (- (-> pl :y) (-> e :y))
        (set! (-> e :a) angle)
        (let ([x (call cos angle)] [y (call sin angle)] [dist (call dist e pl)]) (when (or (and (< (call abs dist) (-> e :agro)) (< (call abs (- (-> pl :x) (-> e :x))) 128)) (== e p)) (return (call cansee e angle x y dist)) (when (and (and (and (< (call abs dist) (-> e :seerange)) (> (call abs dist) (-> e :agro))) (-> e :chase)) (call cansee e angle x y dist)) (set! o (+ (-> e :dx) (-> e :dy))) (set! (-> e :dx) (/ (* x (* (-> e :spd) 2)) (call max dist 4))) (set! (-> e :dy) (/ (* y (* (-> e :spd) 2)) (call max dist 4))) (set! mouvrnd #f)))))
      (body-lines
        "function canshoot(e,pl)"
        "\tlocal angle = atan2(pl.x-e.x,"
        "\tpl.y-e.y)"
        "\te.a=angle"
        "\tlocal x = cos(angle)"
        "\tlocal y = sin(angle) "
        "\tlocal dist = dist(e,pl)"
        "\t"
        "\tif (abs(dist)<e.agro and abs(pl.x-e.x)<128) or e==p then"
        "\t\treturn cansee(e,angle,x,y,dist)"
        "\telseif abs(dist)<e.seerange and abs(dist)>e.agro and e.chase and cansee(e,angle,x,y,dist) then"
        "  o= e.dx+e.dy"
        "   e.dx=x*(e.spd*2)/max(dist,4)"
        "   e.dy=y*(e.spd*2)/max(dist,4)"
        "   "
        "    mouvrnd = false"
        "   "
        "  "
        " end\t"))
    (def-pico-function #:params (e p) #:returns (val)
      (name dist)
      (params (e p))
      (returns (val))
      (line-range (1776 1778))
      (api-calls (abs sqrt))
      (called-functions ())
      (structured-ast
        (return-expr (/ (call sqrt (+ (expt (call abs (- (-> p :y) (-> e :y))) 2) (expt (call abs (- (-> p :x) (-> e :x))) 2))) 8)))
      (decompiled-pseudo-code
        (return (/ (call sqrt (+ (expt (call abs (- (-> p :y) (-> e :y))) 2) (expt (call abs (- (-> p :x) (-> e :x))) 2))) 8)))
      (body-lines
        "function dist(e,p)"
        "\treturn sqrt(abs(p.y-e.y)^2+abs(p.x-e.x)^2)/8"
        "end"))
    (def-pico-function #:params (e angle x y dist) #:returns (val)
      (name cansee)
      (params (e angle x y dist))
      (returns (val))
      (line-range (1780 1787))
      (api-calls (add))
      (called-functions (delchecker is_solid))
      (structured-ast
        (for-loop "i =1,dist")
        (if-cond (call is_solid (+ (-> (aref checker (len checker)) :x) 4) (+ (-> (aref checker (len checker)) :y) 4)))
        (if-cond (!= e p))
        (return-expr #f))
      (decompiled-pseudo-code
        (for-range i 1 dist (call add checker (table (:x (+ (-> e :x) (* (* x i) 8))) (:y (+ (-> e :y) (* (* y i) 8))))) (when (call is_solid (+ (-> (aref checker (len checker)) :x) 4) (+ (-> (aref checker (len checker)) :y) 4)) (call delchecker) (when (!= e p) (set! (-> (-> e :gun) :timer) (/ (-> (-> e :gun) :cooldown) 2))) (return #f))))
      (body-lines
        "function cansee(e,angle,x,y,dist)\t "
        " for i =1,dist do"
        "\tadd(checker,{x=e.x+x*i*8,y=e.y+y*i*8})  "
        "\t if is_solid(checker[#checker].x+4,checker[#checker].y+4) then"
        "\t \tdelchecker()"
        "\t \tif (e!=p) e.gun.timer = e.gun.cooldown/2"
        "\t return false "
        "\t end"))
    (def-pico-function #:params () #:returns ()
      (name delchecker)
      (params ())
      (returns ())
      (line-range (1794 1796))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! checker (table)))
      (body-lines
        "function delchecker()"
        "\tchecker = {}"
        "end"))
    (def-pico-function #:params (i) #:returns (val)
      (name loaded)
      (params (i))
      (returns (val))
      (line-range (1798 1800))
      (api-calls (abs))
      (called-functions ())
      (structured-ast
        (return-expr (< (call abs (- (+ camx 64) (-> i :x))) 71)))
      (decompiled-pseudo-code
        (return (< (call abs (- (+ camx 64) (-> i :x))) 71)))
      (body-lines
        "function loaded(i)"
        "\treturn abs(camx+64-i.x)<71--71"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name init_ptc)
      (params ())
      (returns ())
      (line-range (1803 1808))
      (api-calls (add flr rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=0,20"))
      (decompiled-pseudo-code
        (set! particles (table))
        (set! grass (table))
        (for-range i 0 20 (call add grass (table (:x (* (call flr (call rnd 16)) 8)) (:y (* (call flr (call rnd 16)) 8)) (:spr 56)))))
      (body-lines
        "function init_ptc()"
        "\tparticles={}"
        "\tgrass = {}"
        "\tfor i=0,20 do "
        "\tadd(grass,{x=flr(rnd(16))*8, y=flr(rnd(16))*8, spr=56})"
        "\tend"))
    (def-pico-function #:params (x y r col fric dx dy txt) #:returns ()
      (name make_ptc)
      (params (x y r col fric dx dy txt))
      (returns ())
      (line-range (1822 1836))
      (api-calls (add rnd))
      (called-functions ())
      (structured-ast
        (seq-block 15))
      (decompiled-pseudo-code
        (set! fric (or fric (call rnd |.|)))
        (set! dx (or dx 0))
        (set! dy (or dy 0))
        (call add particles (table))
        (set-values! (x) (x y))
        (set-values! (dx) (dx dy))
        (set! fric fric)
        (set! txt txt)
        (set-values! (r) (r col))
        (set! destroy #f)
        |}|)
      (body-lines
        "function make_ptc(x,y,r,col,fric,dx,dy,txt)"
        "\tfric=fric or rnd(.1)+.85"
        "\tdx=dx or 0"
        "\tdy=dy or 0"
        "\tadd(particles, {"
        "\t\tx=x,  y=y,"
        "\t\tdx=dx,dy=dy,"
        "\t\tfric=fric,"
        "\t\t"
        "\t\ttxt=txt,"
        "\t\t"
        "\t\tr=r, col=col,"
        "\t\tdestroy=false,"
        "\t})"
        "end"))
    (def-pico-function #:params (ptc) #:returns ()
      (name update_ptc)
      (params (ptc))
      (returns ())
      (line-range (1838 1848))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond (<= (-> ptc :r) 1)))
      (decompiled-pseudo-code
        (+= (-> ptc :x) (-> ptc :dx))
        (+= (-> ptc :y) (-> ptc :dy))
        (*= (-> ptc :dx) (-> ptc :fric))
        (*= (-> ptc :dy) (-> ptc :fric))
        (*= (-> ptc :r) (-> ptc :fric))
        (when (<= (-> ptc :r) 1) (set! (-> ptc :destroy) #t)))
      (body-lines
        "function update_ptc(ptc)"
        "\tptc.x += ptc.dx"
        "\tptc.y += ptc.dy"
        "\t"
        "\tptc.dx *= ptc.fric"
        "\tptc.dy *= ptc.fric"
        "\t"
        "\tptc.r *= ptc.fric"
        "\t"
        "\tif(ptc.r<=1)ptc.destroy=true"
        "end"))
    (def-pico-function #:params (ptc) #:returns ()
      (name draw_ptc)
      (params (ptc))
      (returns ())
      (line-range (1850 1856))
      (api-calls (circfill print))
      (called-functions ())
      (structured-ast
        (if-cond (== (-> ptc :txt) nil)))
      (decompiled-pseudo-code
        (if (== (-> ptc :txt) nil) (then (call circfill (-> ptc :x) (-> ptc :y) (-> ptc :r) (-> ptc :col))) (else (call print (-> ptc :txt) (-> ptc :x) (-> ptc :y) (-> ptc :col)))))
      (body-lines
        "function draw_ptc(ptc)"
        "\t--kinda bodgey but whatever"
        "\tif ptc.txt==nil then"
        "\t\tcircfill(ptc.x,ptc.y,ptc.r,ptc.col)"
        "\telse"
        "\t\tprint(ptc.txt,ptc.x,ptc.y,ptc.col)"
        "\tend"))
    (def-pico-function #:params (x y col) #:returns ()
      (name burst_ptc)
      (params (x y col))
      (returns ())
      (line-range (1859 1866))
      (api-calls (rnd))
      (called-functions (make_ptc rrnd))
      (structured-ast
        (for-loop "i=1,5"))
      (decompiled-pseudo-code
        (for-range i 1 5 (call make_ptc void) (+ x (call rrnd 8)) (+ y (call rrnd 8)) (+ (call rnd 5) 5) (+ 0.9 (call rnd 0.07))))
      (body-lines
        "function burst_ptc(x,y,col)"
        "\tfor i=1,5 do"
        "\t\tmake_ptc("
        "\t\t   x+rrnd(8),"
        "\t\t   y+rrnd(8),"
        "\t\t   rnd(5)+5,col,"
        "\t\t   0.9+rnd(0.07))"
        "\tend "))
    (def-pico-function #:params () #:returns ()
      (name grasstile)
      (params ())
      (returns ())
      (line-range (1869 1874))
      (api-calls (all))
      (called-functions ())
      (structured-ast
        (if-cond (< (-> i :x) (- 8))))
      (decompiled-pseudo-code
        for
        (set! (-> i :x) (-> i :x))
        (-= (-> i :x) 2.5)
        (when (< (-> i :x) (- 8)) (set! (-> i :x) 128)))
      (body-lines
        "function grasstile()"
        "\tfor i in all(grass)do"
        "\t i.x = i.x"
        "\t\ti.x-=2.5"
        "\t\tif (i.x<-8)i.x = 128"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name drawgrass)
      (params ())
      (returns ())
      (line-range (1877 1880))
      (api-calls (all spr))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        for
        (call spr (-> elt :spr) (+ camx (-> elt :x)) (-> elt :y)))
      (body-lines
        "function drawgrass()"
        "\tfor elt in all(grass)do"
        "\t\tspr(elt.spr,camx+elt.x,elt.y)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name draw_weel)
      (params ())
      (returns ())
      (line-range (1883 1889))
      (api-calls (spr))
      (called-functions ())
      (structured-ast
        (if-cond (< weelcount 1))
        (for-loop "n=0,5")
        (for-loop "i=0,2"))
      (decompiled-pseudo-code
        (-= weelcount 1)
        (when (< weelcount 1) (set! weelflip (not weelflip)))
        (for-range n 0 5 (for-range i 0 2 (call spr 42 (+ (+ 8 (* n 64)) (* i 16)) (* 14 8) 2 2 weelflip))))
      (body-lines
        "function draw_weel()"
        " weelcount -=1"
        " if (weelcount<1) weelflip = not weelflip weelcount=weelframe"
        " for n=0,5 do"
        "\tfor i=0,2 do"
        "\t\tspr(42,8+n*64+i*16,14*8, 2,2,weelflip)--, flip_x ,flip_y)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name init_menus)
      (params ())
      (returns ())
      (line-range (1898 1904))
      (api-calls ())
      (called-functions (make_boss_death make_death_menu make_main_menu))
      (structured-ast
        (seq-block 7))
      (decompiled-pseudo-code
        (set! menus (table))
        (set! (-> menus :main) (call make_main_menu))
        (set! (-> menus :death) (call make_death_menu #f))
        (set! (-> menus :bossdeath) (call make_boss_death))
        (set! (-> menus :win) (call make_death_menu #t)))
      (body-lines
        "function init_menus()"
        "\tmenus = {}"
        "\tmenus.main = make_main_menu()"
        "\tmenus.death = make_death_menu(false)"
        "\tmenus.bossdeath = make_boss_death()"
        "\tmenus.win = make_death_menu(true)"
        "end"))
    (def-pico-function #:params (t x y w w2 c c2) #:returns ()
      (name draw_bar)
      (params (t x y w w2 c c2))
      (returns ())
      (line-range (1907 1915))
      (api-calls (print rectfill))
      (called-functions ())
      (structured-ast
        (seq-block 9))
      (decompiled-pseudo-code
        (call rectfill x y void)
        (+ (+ x w) 2)
        (set! l (* w w2))
        (call rectfill (+ x 1) (+ y 1) void)
        (+ (+ x 1) l)
        (call print t (+ x 1) (+ y 1) 7))
      (body-lines
        "function draw_bar(t,x,y,w,w2,c,c2)"
        "\trectfill(x,y,"
        "\tx+w+2,y+5,c2)"
        "\tlocal l=w*w2"
        "\trectfill(x+1,y+1,"
        "\tx+1+l,y+5,c)"
        "\t"
        "\tprint(t, x+1,y+1,7)"
        "end--]]"))
    (def-pico-function #:params () #:returns ()
      (name make_boss_death)
      (params ())
      (returns ())
      (line-range (1917 1920))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! m (table))
        (set! timer 400))
      (body-lines
        "function make_boss_death()"
        "\tlocal m={"
        "\ttimer=400,"
        "\t"))
    (def-pico-function #:params (m) #:returns ()
      (name update)
      (params (m))
      (returns ())
      (line-range (1921 1940))
      (api-calls (all del music rnd sfx))
      (called-functions (make_ptc))
      (structured-ast
        (if-cond (== (-> m :timer) 400))
        (if-cond (< (-> m :timer) 0))
        (for-loop "i=1,18"))
      (decompiled-pseudo-code
        for
        (call music (- 1) 0)
        (when (== (-> m :timer) 400) (call sfx 45))
        (-= (-> m :timer) 3)
        (when (< (-> m :timer) 0) (set! menu "game") (set! win #t) (+= shake 40) (call sfx 48) (for-range i 1 18 (call make_ptc (+ camx (call rnd 128)) void) (call rnd 128) rnd)))
      (body-lines
        "\tupdate=function(m)"
        "\t\tfor e in all(enemies)do del(e,enemies) end"
        "\t\tmusic(-1,0)"
        "\t\tif(m.timer==400)sfx(45)--sfx(46)"
        "\t\t"
        "\t\tm.timer -= 3"
        "\t\t"
        "\t\tif m.timer<0 then"
        "\t\t\tmenu = \"game\""
        "\t\t\twin=true"
        "\t\t\tshake += 40"
        "\t\t\tsfx(48)"
        "\t\t\t"
        "\t\t\tfor i=1,18 do"
        "\t\t\t\tmake_ptc(camx+rnd(128),"
        "\t\t\t\trnd(128),50+rnd(20),"
        "\t\t\t\trnd{8,9,10},.95)"
        "\t\t\t\t"
        "--(x,y,r,col,fric,dx,dy,txt)"
        "\t\t\tend"))
    (def-pico-function #:params (m) #:returns ()
      (name draw)
      (params (m))
      (returns ())
      (line-range (1946 1956))
      (api-calls (circfill spr))
      (called-functions ())
      (structured-ast
        (seq-block 11))
      (decompiled-pseudo-code
        (let ([x (+ (aref boss_pos 1) 8)] [y (+ (aref boss_pos 2) 8)] [flp (aref boss_pos 3)] [t (-> m :timer)]) (call circfill x y t 8))
        (call circfill x y (* t |.|))
        (call circfill x y (* t |.|))
        (call circfill x y (* t |.|))
        (call spr 1 (- x 8) (- y 8) 2 2 flp))
      (body-lines
        "\tdraw=function(m)"
        "\t\t"
        "\t\tlocal x,y = boss_pos[1]+8,boss_pos[2]+8"
        "\t\tlocal flp = boss_pos[3]"
        "\t\tlocal t = m.timer"
        "\t\tcircfill(x,y,t    ,8)"
        "\t\tcircfill(x,y,t*.75,9)"
        "\t\tcircfill(x,y,t*.5 ,10)"
        "\t\tcircfill(x,y,t*.25,7)"
        "\t\tspr(1,x-8,y-8,2,2,flp)"
        "\tend"))
    (def-pico-function #:params () #:returns ()
      (name make_main_menu)
      (params ())
      (returns ())
      (line-range (1962 1996))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (for-loop "i=1,12"))
      (decompiled-pseudo-code
        (set! m (table))
        (set! update update_main_menu)
        (set! draw draw_main_menu)
        (set! sel 0)
        (set! done #f)
        (set! ui_oy 0)
        (set! ui_dy 0)
        (set! has_active #f)
        |}|
        (set! (-> m :buttons) (table))
        (let ([names split] [x 4] [y 105]) (for-range i 1 12 (call add (-> m :buttons) (table)) (set! n i) (set! spr (+ i 79)) (set! bird (+ i 111)) (set! x (- (* i 10) 6)) (set! y 105) (set! w 9) (set! h 17) (set! col 1) (set! sh 2) (set! name (aref names i)) (set! active #f) |}|)))
      (body-lines
        "function make_main_menu()"
        "\t--this code could be better"
        "\tlocal m = {"
        "\t  update=update_main_menu,"
        "\t  draw=draw_main_menu,"
        "\t  "
        "\t  sel=0,"
        "\t  done=false,"
        "\t  ui_oy=0,"
        "\t  ui_dy=0,"
        "\t  "
        "\t  has_active=false,"
        "\t}"
        "\tm.buttons={}"
        "\t"
        "\tlocal names=split\"pigeon,duck,sparrow,parrot,toucan,flamingo,eagle,seagull,ostrich,penguin,jay,chicken\""
        "\tlocal x=4"
        "\tlocal y=105"
        "\tfor i=1,12 do"
        "\t\tadd(m.buttons,{"
        "\t\t  n=i,"
        "\t\t  spr=i+79,"
        "\t\t  bird=i+111,"
        "\t\t  "
        "\t\t  x=i*10-6,"
        "\t\t  y=105,"
        "\t\t  w=9,"
        "\t\t  h=17,"
        "\t\t  col=1,"
        "\t\t  sh=2,"
        "\t\t  "
        "\t\t  name=names[i],"))
    (def-pico-function #:params (args) #:returns (val)
      (name make_btn)
      (params (args))
      (returns (val))
      (line-range (1999 2016))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr (table)))
      (decompiled-pseudo-code
        (set-values! (n sp bird x y w h name) ((call unpack (call split args))))
        (return (table))
        (set! n n)
        (set! spr sp)
        (set! bird bird)
        (set-values! (x) (x y))
        (set-values! (w) (w h))
        (set! oy 0)
        (set! col 1)
        (set! sh 1)
        (set! name name)
        (set! active #f)
        |}|)
      (body-lines
        "\tfunction make_btn(args)"
        "\t\tn,sp,bird,x,y,w,h,name=unpack(split(args))"
        "\t\treturn {"
        "\t\t  n=n,"
        "\t\t  spr=sp,"
        "\t\t  bird=bird,"
        "\t\t  "
        "\t\t  x=x,y=y,"
        "\t\t  w=w,h=h,"
        "\t\t  "
        "\t\t  oy=0,"
        "\t\t  col=1,"
        "\t\t  sh=1,"
        "\t\t  "
        "\t\t  name=name,"
        "\t\t  active=false,"
        "\t\t}"
        "\tend"))
    (def-pico-function #:params (m) #:returns ()
      (name update_main_menu)
      (params (m))
      (returns ())
      (line-range (2025 2047))
      (api-calls (sfx))
      (called-functions (touches_rect))
      (structured-ast
        (if-cond (not (-> m :done)))
        (for-loop "k=0,#m.buttons")
        (if-cond (not (-> i :active)))
        (if-cond lmb))
      (decompiled-pseudo-code
        (let ([selection 1000]) (when (not (-> m :done)) (for-range k 0 (len (-> m :buttons)) (set! i (aref (-> m :buttons) k)) if (- (+ (-> i :x) (-> i :w)) 1) (set! (-> i :col) 7) (set! (-> i :oy) 2) (when (not (-> i :active)) (call sfx 43)) (set! (-> m :has_active) #t) (set! (-> m :sel) (-> i :n)) (set! (-> i :active) #t) (when lmb (set! selection (-> i :n)))))))
      (body-lines
        "function update_main_menu(m)"
        "\tlocal selection=1000"
        "\t"
        "\tif not m.done then"
        "\t\t--update buttons"
        "\t\tfor k=0,#m.buttons do"
        "\t\t\tlocal i = m.buttons[k]"
        "\t\t\t"
        "\t\t\t--on hover"
        "\t\t\tif touches_rect(mx,my,i.x,i.y,"
        "\t\t\ti.x+i.w-1, i.y+i.h-1) then"
        "\t\t\t\ti.col = 7"
        "\t\t\t\ti.oy = 2"
        "\t\t\t\t"
        "\t\t\t\tif(not i.active) sfx(43)"
        "\t\t\t\tm.has_active=true"
        "\t\t\t\tm.sel = i.n"
        "\t\t\t\ti.active=true"
        "\t\t\t\t"
        "\t\t\t\t-- on click"
        "\t\t\t\tif lmb then "
        "\t\t\t\t\tselection = i.n"
        "\t\t\t\tend"))
    (def-pico-function #:params (m) #:returns ()
      (name draw_main_menu)
      (params (m))
      (returns ())
      (line-range (2097 2133))
      (api-calls (abs palt rectfill spr))
      (called-functions (draw_logo oprint))
      (structured-ast
        (for-loop "k=0,#m.buttons")
        (if-cond (== k 13))
        (if-cond (and (== (-> i :n) 13) (-> i :active))))
      (decompiled-pseudo-code
        (set! oy (-> m :ui_oy))
        (call palt 0 #f)
        (call draw_logo 44 (- 5 oy))
        (call rectfill 112 (+ 89 oy) 125 (+ 110 oy) 12)
        (call rectfill 2 (+ 103 oy) 125 (+ 124 oy) 1)
        (for-range k 0 (len (-> m :buttons)) (set! i (aref (-> m :buttons) k)) (set! oy (call abs oy)) (when (== k 13) (set! oy (- oy))) (call rectfill (-> i :x) void) (+ (- (-> i :y) (-> i :oy)) oy) (+ (-> i :x) (-> i :w)) (+ (- (+ (-> i :y) (-> i :h)) (-> i :oy)) oy) (-> i :col) (call spr (-> i :spr) void) (+ (-> i :x) 1) (+ (- (+ (-> i :y) 1) (-> i :oy)) oy) 1 (when (and (== (-> i :n) 13) (-> i :active)) (call oprint "a game by:" 2 13 14) (call oprint (aref |[| yOLWOOCLE)) gOUSPOURD nOTGOYOME sIMON (call oprint (aref |[| code) art) code code music)))
      (body-lines
        "function draw_main_menu(m)"
        "\tlocal oy = m.ui_oy"
        "\t"
        "\tpalt(0,false)"
        "\t"
        "\tdraw_logo(44,5-oy)"
        "\t"
        "\t--player selection"
        "\trectfill(112,89+oy,125,110+oy,12)"
        "\trectfill(2,103+oy,125,124+oy,1)"
        "\tfor k=0,#m.buttons do"
        "\t\ti = m.buttons[k]"
        "\t\t"
        "\t\toy = abs(oy)"
        "\t\tif(k == 13)oy = -oy"
        "\t\t"
        "\t\trectfill(i.x, "
        "\t\ti.y-i.oy + oy, "
        "\t\ti.x+i.w, "
        "\t\ti.y+i.h-i.oy + oy, "
        "\t\ti.col)"
        "\t\tspr(i.spr, "
        "\t\ti.x+1, "
        "\t\ti.y+1-i.oy + oy,"
        "\t\t1,i.sh)"
        "\t\t"
        "\t\tif i.n==13and i.active then"
        "\t\t\toprint(\"a game by:\",2,13, 14)"
        "\t\t\toprint([[yOLWOOCLE"
        "gOUSPOURD"
        "nOTGOYOME"
        "sIMON t.]],2,13)"))
    (def-pico-function #:params (x y) #:returns ()
      (name draw_logo)
      (params (x y))
      (returns ())
      (line-range (2152 2161))
      (api-calls ())
      (called-functions (oprint oxxl))
      (structured-ast
        (seq-block 10))
      (decompiled-pseudo-code
        (call oxxl "birds" x y 10)
        (call oxxl "guns" (+ x 4) (+ y 15) 6)
        (call oprint "with" (+ x 11) (+ y 10))
        (call oprint "with" (+ x 11) (+ y 9)))
      (body-lines
        "function draw_logo(x,y)"
        "\t--\"birds\""
        "\toxxl(\"birds\",x,y,10)"
        "\toxxl(\"guns\",x+4,y+15, 6)"
        "\t"
        "\t--\"with\""
        "\toprint(\"with\",x+11,y+10)"
        "\t"
        "\toprint(\"with\",x+11,y+9)"
        "end"))
    (def-pico-function #:params (t x y col) #:returns ()
      (name oxxl)
      (params (t x y col))
      (returns ())
      (line-range (2163 2170))
      (api-calls (abs print))
      (called-functions ())
      (structured-ast
        (for-loop "ix=-2,2")
        (for-loop "iy=-2,4")
        (if-cond (call abs ix)))
      (decompiled-pseudo-code
        (for-range ix (- 2) 2 (for-range iy (- 2) 4 if or (call print (string-append "\\^p" t) (+ x ix) (+ y iy) 1))))
      (body-lines
        "function oxxl(t,x,y,col)"
        "\t--credit to freds72"
        "\tfor ix=-2,2 do"
        "\t\tfor iy=-2,4 do"
        "\t\t\tif abs(ix)==2 "
        "\t\t\tor abs(iy)>=2 then"
        "\t\t\t\tprint(\"\\^p\"..t,x+ix,y+iy,1)"
        "\t\t\tend"))
    (def-pico-function #:params (t x y col pre) #:returns ()
      (name wide)
      (params (t x y col pre))
      (returns ())
      (line-range (2183 2195))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "i=1,#t"))
      (decompiled-pseudo-code
        (set! t1 "                ! #$%&'()  ,-./[12345[7[9:;<=>?([[c[efc[ij[l[[([([st[[[&yz[\\\\]'_`[[c[efc[ij[l[[([([st[[[&yz{|}~")
        (set! t2 "                !\\")
        (set-values! (n1 n2) ("" ""))
        (set! pre (or pre ""))
        (for-range i 1 (len t) (let ((char (call sub t i i)) (c (- (call ord char) 16))) (set! (string-append n1 void) (string-append (call sub t1 c c) " "))) (set! (string-append n2 void) (string-append (call sub t2 c c) " "))))
      (body-lines
        "function wide(t,x,y,col,pre)"
        "\t--credit to yolwoocle uwu"
        "\tt1= \"                ! #$%&'()  ,-./[12345[7[9:;<=>?([[c[efc[ij[l[[([([st[[[&yz[\\\\]'_`[[c[efc[ij[l[[([([st[[[&yz{|}~\""
        "\tt2=\"                !\\\"=$  '()*+,-./0123]5678]:;<=>?@abcdefghijklmnopqrstuvwx]z[\\\\]^_`abcdefghijklmnopqrstuvwx]z{|} \""
        "\tn1,n2=\"\",\"\""
        "\tpre=pre or \"\""
        "\t"
        "\tfor i=1,#t do"
        "\t\tlocal char = sub(t,i,i)"
        "\t\tlocal c=ord(char)-16"
        "\t\tn1..=sub(t1,c,c)..\" \""
        "\t\tn2..=sub(t2,c,c)..\" \""
        "\tend"))
    (def-pico-function #:params (x y spr type q) #:returns ()
      (name make_drop)
      (params (x y spr type q))
      (returns ())
      (line-range (2205 2219))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (seq-block 15))
      (decompiled-pseudo-code
        (call add drops (table))
        (set-values! (x) (x y))
        (set-values! (bx) (8 dy))
        (set! spr spr)
        (set! type type)
        (set! q q)
        (set! touched #f)
        (set! cooldown 0)
        (set! destroy #f)
        |}|)
      (body-lines
        "function make_drop(x,y,spr,type,q)"
        "\tadd(drops,{"
        "\t x=x, y=y,"
        "\t bx=8,dy=8,"
        "\t "
        "\t spr=spr,"
        "\t type=type,"
        "\t "
        "\t q=q,"
        "\t touched=false,"
        "\t cooldown=0,"
        "\t "
        "\t destroy=false,"
        "\t})"
        "end"))
    (def-pico-function #:params () #:returns ()
      (name update_drops)
      (params ())
      (returns ())
      (line-range (2221 2272))
      (api-calls (all flr max sfx))
      (called-functions (touches_rect update_gun))
      (structured-ast
        (for-loop "d in all(drops)")
        (if-cond (not touches))
        (if-cond touches)
        (if-cond (== (-> d :type) "ammo")))
      (decompiled-pseudo-code
        (foreach d drops (set! (-> d :cooldown) (call max 0 (- (-> d :cooldown) 1))) (set! touches (call touches_rect void)) (+ (-> p :x) 4) (-> d :x) (when (not touches) (set! (-> d :touched) #f)) (when touches (let ((col 7) (txt "") (do_ptc #f)) (when (== (-> d :type) "ammo") (set! (-> d :destroy) #t) (let ((q (call flr (* (-> d :q) (-> (-> p :gun) :maxammo))))) (+= (-> (-> p :gun) :ammo) q)) (set! do_ptc #t) (set! col 9) (set! txt (string-append "+" (string-append q " ammo"))) (call sfx 38) elseif (set! (-> d :destroy) #t) (+= (-> p :life) (-> d :q)) (set! do_ptc #t) (set! col 8) (set! txt (string-append "+" (string-append (-> d :q) " health"))) (call sfx 38) elseif and and (set! (-> d :touched) #t) (set! (-> d :cooldown) 60) (set! do_ptc #t) (set! col 6) (set! txt (-> (-> d :q) :name)) (set-values! ((aref (-> p :gunls) (-> p :gunn)) (-> d :q)) ((-> d :q) (aref (-> p :gunls) (-> p :gunn)))) (call update_gun p) (set! (-> d :spr) (-> (-> d :q) :spr)) (call sfx 36))))))
      (body-lines
        "function update_drops()"
        "\tfor d in all(drops) do"
        "\t\td.cooldown=max(0,d.cooldown-1)"
        "\t\t"
        "\t\tlocal touches = touches_rect("
        "\t\tp.x+4,p.y+4,"
        "\t\td.x,d.y,d.x+8,d.y+8)"
        "\t\t"
        "\t\tif(not touches)d.touched=false"
        "\t\tif touches then"
        "\t\t\t"
        "\t\t\tlocal col=7"
        "\t\t\tlocal txt=\"\""
        "\t\t\tlocal do_ptc = false"
        "\t\t\t"
        "\t\t\tif d.type==\"ammo\" then"
        "\t\t\t\td.destroy = true"
        "\t\t\t\tlocal q = flr(d.q*p.gun.maxammo)"
        "\t\t\t\tp.gun.ammo += q"
        "\t\t\t\t"
        "\t\t\t\tdo_ptc=true"
        "\t\t\t\tcol=9"
        "\t\t\t\ttxt=\"+\"..q..\" ammo\""
        "\t\t\t\t"
        "\t\t\t\tsfx(38)"
        "\t\t\t\t"
        "\t\t\telseif d.type==\"health\"then"
        "\t\t\t\td.destroy = true"
        "\t\t\t\tp.life += d.q"
        "\t\t\t\t"
        "\t\t\t\tdo_ptc=true"
        "\t\t\t\tcol=8"))
    (def-pico-function #:params () #:returns ()
      (name draw_drops)
      (params ())
      (returns ())
      (line-range (2296 2299))
      (api-calls (all spr))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        for
        (call spr (-> d :spr) (-> d :x) (-> d :y)))
      (body-lines
        "function draw_drops()"
        "\tfor d in all(drops)do"
        "\t\tspr(d.spr,d.x,d.y)"
        "\tend"))
    (def-pico-function #:params (x y) #:returns ()
      (name spawn_loot)
      (params (x y))
      (returns ())
      (line-range (2302 2317))
      (api-calls (rnd))
      (called-functions (copy make_drop rnd_gun))
      (structured-ast
        (if-cond (< r |.|)))
      (decompiled-pseudo-code
        (let ([r (call rnd 1)]) (when (< r |.|) (let ([g (call rnd_gun)]) (call make_drop x y (-> g :spr) "gun" void)) (call copy g) (when (< r |.|) (call make_drop x y 79 "ammo" (/ 1 4)) (when (< r |.|) (call make_drop x y 78 "health" 2) (when (< r |.|) (call make_drop x y 78 "health" 1)))))))
      (body-lines
        "function spawn_loot(x,y)"
        "\tlocal r = rnd(1)"
        "\t"
        "\tif r < .015 then"
        "\t\tlocal g = rnd_gun()"
        "\t\tmake_drop(x,y,g.spr,\"gun\","
        "\t\tcopy(g))"
        "\telseif r < .045 then"
        "\t\tmake_drop(x,y,79,\"ammo\",1/4)"
        "\t\t"
        "\telseif r < .075 and degaplus == 0 then"
        "\t\tmake_drop(x,y,78,\"health\",2)"
        "\t"
        "\telseif r < .017 and degaplus == 1 then"
        "\t\tmake_drop(x,y,78,\"health\",1)"
        "\tend"))
    (def-pico-function #:params (iswin) #:returns (val)
      (name make_death_menu)
      (params (iswin))
      (returns (val))
      (line-range (2321 2352))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond iswin)
        (return-expr m))
      (decompiled-pseudo-code
        (set! m (table))
        (set! update update_death_menu)
        (set! draw draw_death_menu)
        (set! circt 1)
        (set! timer 0)
        (set! showtext #f)
        (set! iswin iswin)
        (set! nstats 0)
        |}|
        (let ([t "retry"] [t2 "change bird"]) (when iswin (set-values! (t) ("play again" "title screen"))))
        (set! (-> m :buttons) (table))
        (set! (aref (-> m :buttons) 1) (table))
        (set! n 1)
        (set! t t)
        (set-values! (x) (0 y oy))
        (set! active #f)
        |}|
        (set! (aref (-> m :buttons) 2) (table))
        (set! n 2)
        (set! t t2)
        (set-values! (x) (0 y oy))
        (set! active #f)
        |}|)
      (body-lines
        "function make_death_menu(iswin)"
        "\tlocal m = {"
        "\t  update=update_death_menu,"
        "\t  draw=draw_death_menu,"
        "\t  "
        "\t  circt=1,"
        "\t  timer=0,"
        "\t  showtext=false,"
        "\t  "
        "\t  iswin=iswin,"
        "\t  nstats=0,"
        "\t}"
        "\t"
        "\tlocal t,t2=\"retry\",\"change bird\""
        "\tif(iswin)t=\"play again\",\"title screen\""
        "\t"
        "\tm.buttons = {}"
        "\tm.buttons[1]={"
        "\t\tn=1,"
        "\t\tt=t,"
        "\t\tx=0,y=0, oy=0,"
        "\t\tactive=false"
        "\t}"
        "\tm.buttons[2]={"
        "\t\tn=2,"
        "\t\tt=t2,"
        "\t\tx=0,y=0, oy=0,"
        "\t\tactive=false"
        "\t}"
        "\t"
        "\treturn m"
        "end"))
    (def-pico-function #:params (m) #:returns ()
      (name update_death_menu)
      (params (m))
      (returns ())
      (line-range (2354 2368))
      (api-calls (min music sfx))
      (called-functions ())
      (structured-ast
        (if-cond (>= (-> m :circt) 600))
        (if-cond (== (-> m :timer) 0))
        (if-cond (== (-> m :timer) 220)))
      (decompiled-pseudo-code
        (set! (-> m :circt) (call min (* (-> m :circt) 1.05) 600))
        (when (>= (-> m :circt) 600) (when (== (-> m :timer) 0) (call music 23)) (when (== (-> m :timer) 220) (call music 24)) if and (call sfx 41) (+= (-> m :nstats) 1)))
      (body-lines
        "function update_death_menu(m)"
        "\tm.circt=min(m.circt*1.05,600)"
        "\t"
        "\t--circle timer"
        "\tif m.circt>=600 then"
        "\t\tif(m.timer==0) music(23)"
        "\t\t"
        "\t\tif(m.timer==220) music(24)"
        "\t\tif m.timer%60==59 "
        "\t\t"
        "\t\t--\"ploop\" sfx on every stat"
        "\t\tand m.nstats<3 then"
        "\t\t\tsfx(41) "
        "\t\t\tm.nstats+=1"
        "\t\tend"))
    (def-pico-function #:params (m) #:returns ()
      (name draw_death_menu)
      (params (m))
      (returns ())
      (line-range (2414 2424))
      (api-calls (palt))
      (called-functions ())
      (structured-ast
        (if-cond (-> m :iswin))
        (if-cond (call t void)))
      (decompiled-pseudo-code
        (call palt 0 #f)
        (call palt 1 #t)
        (let ([col 0] [c2 1] [c3 2] [c4 9] [txtcol 7]) (when (-> m :iswin) (set-values! (col c2 c3 c4) (15 9 8 2)) (set! txtcol 10) (when (< (modulo (call t) 2) 1) (set! txtcol 9)))))
      (body-lines
        "function draw_death_menu(m)"
        "\t--circles animation"
        "\tpalt(0,false)"
        "\tpalt(1,true)"
        "\tlocal col,c2,c3,c4=0,1,2,9"
        "\tlocal txtcol = 7"
        "\tif m.iswin then"
        "\t\tcol,c2,c3,c4=15,9,8,2"
        "\t\ttxtcol = 10"
        "\t\tif(t()%2<1)txtcol = 9"
        "\tend")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id #x00 #:grid (0 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00700700" "00077000" "00077000" "00700700" "00000000" "00000000"))
      (def-pico-sprite #:id #x01 #:grid (1 0) #:nonzero-pixels 42 #:rows ("000d5000" "00057500" "00057779" "07005769" "77604999" "77704559" "67907485" "09906788"))
      (def-pico-sprite #:id #x02 #:grid (2 0) #:nonzero-pixels 40 #:rows ("00005d00" "00057500" "44677500" "99976d00" "99999900" "99995900" "59559400" "99884000"))
      (def-pico-sprite #:id #x03 #:grid (3 0) #:nonzero-pixels 64 #:rows ("77777777" "77777777" "77777777" "99999999" "77777777" "11111111" "11111111" "11111111"))
      (def-pico-sprite #:id #x04 #:grid (4 0) #:nonzero-pixels 32 #:rows ("00000000" "6d000066" "ddd006dd" "07776760" "06666660" "6dd00dd6" "dd0000dd" "00000000"))
      (def-pico-sprite #:id #x05 #:grid (5 0) #:nonzero-pixels 64 #:rows ("11111111" "11111111" "11111111" "77777777" "99999999" "77777777" "77777777" "77777777"))
      (def-pico-sprite #:id #x06 #:grid (6 0) #:nonzero-pixels 64 #:rows ("77777776" "7d6116dd" "7611116d" "7611116d" "7661166d" "7661166d" "7d6666dd" "6ddddddd"))
      (def-pico-sprite #:id #x07 #:grid (7 0) #:nonzero-pixels 64 #:rows ("6666666d" "65dddd55" "6dddddd5" "6dddddd5" "6dddddd5" "6dddddd5" "65dddd55" "d5555555"))
      (def-pico-sprite #:id #x08 #:grid (8 0) #:nonzero-pixels 64 #:rows ("44444444" "24444422" "22244444" "44444224" "44444444" "42224444" "44444444" "22222222"))
      (def-pico-sprite #:id #x09 #:grid (9 0) #:nonzero-pixels 64 #:rows ("44444444" "44444444" "22222222" "22222222" "44444444" "44444444" "22222222" "22222222"))
      (def-pico-sprite #:id #x0A #:grid (10 0) #:nonzero-pixels 64 #:rows ("44444444" "44444444" "44444444" "44444444" "44444444" "44444444" "22222222" "22222222"))
      (def-pico-sprite #:id #x0B #:grid (11 0) #:nonzero-pixels 64 #:rows ("44444444" "24411422" "22211444" "444d1224" "444d4444" "422d4444" "44464444" "22262222"))
      (def-pico-sprite #:id #x0C #:grid (12 0) #:nonzero-pixels 64 #:rows ("eeeeeeee" "eeeeeeee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee"))
      (def-pico-sprite #:id #x0D #:grid (13 0) #:nonzero-pixels 64 #:rows ("ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee"))
      (def-pico-sprite #:id #x0E #:grid (14 0) #:nonzero-pixels 64 #:rows ("11eeee11" "1eeeeee1" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee"))
      (def-pico-sprite #:id #x0F #:grid (15 0) #:nonzero-pixels 64 #:rows ("ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "ee1111ee" "8eeeeee8" "88eeee88"))
      (def-pico-sprite #:id #x10 #:grid (0 1) #:nonzero-pixels 64 #:rows ("77777777" "77777777" "77777777" "77777777" "77777777" "77777777" "77777777" "77777777"))
      (def-pico-sprite #:id #x11 #:grid (1 1) #:nonzero-pixels 49 #:rows ("04990777" "000ddd67" "00dd6666" "0055dddd" "05557777" "56d55666" "5dd55666" "05550000"))
      (def-pico-sprite #:id #x12 #:grid (2 1) #:nonzero-pixels 48 #:rows ("71176000" "77777000" "6d886700" "d28e8600" "d2888650" "6d286755" "66677d55" "00005550"))
      (def-pico-sprite #:id #x13 #:grid (3 1) #:nonzero-pixels 40 #:rows ("77777776" "7000770d" "7007700d" "7077000d" "7770700d" "7707000d" "7070000d" "6dddddd6"))
      (def-pico-sprite #:id #x14 #:grid (4 1) #:nonzero-pixels 64 #:rows ("22222222" "22222222" "42444444" "24444444" "42444467" "24444444" "22444444" "24444442"))
      (def-pico-sprite #:id #x15 #:grid (5 1) #:nonzero-pixels 64 #:rows ("44444441" "44444441" "44444441" "44444441" "44444441" "44444421" "22222221" "22222211"))
      (def-pico-sprite #:id #x16 #:grid (6 1) #:nonzero-pixels 64 #:rows ("12211111" "21124111" "11444421" "12244421" "24224221" "24422211" "12424421" "12212221"))
      (def-pico-sprite #:id #x17 #:grid (7 1) #:nonzero-pixels 16 #:rows ("55555555" "55555555" "00000000" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id #x18 #:grid (8 1) #:nonzero-pixels 64 #:rows ("44244244" "44244244" "42244444" "42444442" "42424442" "44424442" "44444444" "44444244"))
      (def-pico-sprite #:id #x19 #:grid (9 1) #:nonzero-pixels 64 #:rows ("14444444" "14444444" "14444444" "14444444" "14444444" "12444444" "12222222" "11222222"))
      (def-pico-sprite #:id #x1A #:grid (10 1) #:nonzero-pixels 64 #:rows ("111bb111" "111331b1" "1b133131" "13133331" "13333411" "11433411" "11444411" "11222211"))
      (def-pico-sprite #:id #x1B #:grid (11 1) #:nonzero-pixels 64 #:rows ("44464444" "24464422" "22264444" "44464114" "444d1441" "42ddd441" "11444414" "22111122"))
      (def-pico-sprite #:id #x1C #:grid (12 1) #:nonzero-pixels 64 #:rows ("66666666" "66666666" "66666666" "66666666" "66666666" "77777777" "dddddddd" "dddddddd"))
      (def-pico-sprite #:id #x1D #:grid (13 1) #:nonzero-pixels 64 #:rows ("14444441" "14444441" "14444441" "14464441" "14434441" "14b33441" "14bb3441" "14b33441"))
      (def-pico-sprite #:id #x1E #:grid (14 1) #:nonzero-pixels 64 #:rows ("eeeeeeee" "eeeeeeee" "11111111" "11111111" "11111111" "11111111" "eeeeeeee" "eeeeeeee"))
      (def-pico-sprite #:id #x1F #:grid (15 1) #:nonzero-pixels 64 #:rows ("888e8ee8" "888e8ee8" "888e8ee8" "888e8ee8" "888e8ee8" "188e8ee1" "118e8e11" "11111111")))
    (gff-flags
      (def-pico-sprite-flag #:id #x02 #:flags 4)
      (def-pico-sprite-flag #:id #x03 #:flags 4)
      (def-pico-sprite-flag #:id #x05 #:flags 4)
      (def-pico-sprite-flag #:id #x06 #:flags 1)
      (def-pico-sprite-flag #:id #x08 #:flags 4)
      (def-pico-sprite-flag #:id #x09 #:flags 4)
      (def-pico-sprite-flag #:id #x0A #:flags 3)
      (def-pico-sprite-flag #:id #x0B #:flags 4)
      (def-pico-sprite-flag #:id #x0C #:flags 1)
      (def-pico-sprite-flag #:id #x0D #:flags 1)
      (def-pico-sprite-flag #:id #x0E #:flags 1)
      (def-pico-sprite-flag #:id #x0F #:flags 1)
      (def-pico-sprite-flag #:id #x10 #:flags 8)
      (def-pico-sprite-flag #:id #x13 #:flags 1)
      (def-pico-sprite-flag #:id #x14 #:flags 3)
      (def-pico-sprite-flag #:id #x15 #:flags 3)
      (def-pico-sprite-flag #:id #x17 #:flags 17)
      (def-pico-sprite-flag #:id #x18 #:flags 4)
      (def-pico-sprite-flag #:id #x19 #:flags 3)
      (def-pico-sprite-flag #:id #x1A #:flags 3)
      (def-pico-sprite-flag #:id #x1B #:flags 4)
      (def-pico-sprite-flag #:id #x1C #:flags 17)
      (def-pico-sprite-flag #:id #x1D #:flags 3)
      (def-pico-sprite-flag #:id #x1E #:flags 1)
      (def-pico-sprite-flag #:id #x1F #:flags 1)
      (def-pico-sprite-flag #:id #x20 #:flags 3)
      (def-pico-sprite-flag #:id #x21 #:flags 11)
      (def-pico-sprite-flag #:id #x22 #:flags 11)
      (def-pico-sprite-flag #:id #x23 #:flags 11)
      (def-pico-sprite-flag #:id #x24 #:flags 1)
      (def-pico-sprite-flag #:id #x25 #:flags 1)
      (def-pico-sprite-flag #:id #x26 #:flags 1)
      (def-pico-sprite-flag #:id #x27 #:flags 4)
      (def-pico-sprite-flag #:id #x28 #:flags 1)
      (def-pico-sprite-flag #:id #x29 #:flags 1)
      (def-pico-sprite-flag #:id #x2A #:flags 1)
      (def-pico-sprite-flag #:id #x2B #:flags 1)
      (def-pico-sprite-flag #:id #x2C #:flags 1)
      (def-pico-sprite-flag #:id #x2D #:flags 3)
      (def-pico-sprite-flag #:id #x2E #:flags 1)
      (def-pico-sprite-flag #:id #x2F #:flags 4)
      (def-pico-sprite-flag #:id #x30 #:flags 3)
      (def-pico-sprite-flag #:id #x31 #:flags 11)
      (def-pico-sprite-flag #:id #x32 #:flags 11)
      (def-pico-sprite-flag #:id #x33 #:flags 11)
      (def-pico-sprite-flag #:id #x34 #:flags 1)
      (def-pico-sprite-flag #:id #x35 #:flags 1)
      (def-pico-sprite-flag #:id #x36 #:flags 1))
    (map-rows
      (def-pico-map-row #:y #x00 #:nonzero-tiles 65 #:sample-hex "39393939393939393939393939393939")
      (def-pico-map-row #:y #x01 #:nonzero-tiles 100 #:sample-hex "0c282828282829292829290c39393939")
      (def-pico-map-row #:y #x02 #:nonzero-tiles 100 #:sample-hex "0d212727272727272727272829290c39")
      (def-pico-map-row #:y #x03 #:nonzero-tiles 100 #:sample-hex "0d212727272727272727272f27272813")
      (def-pico-map-row #:y #x04 #:nonzero-tiles 100 #:sample-hex "0d272727272727272727272f27273f13")
      (def-pico-map-row #:y #x05 #:nonzero-tiles 104 #:sample-hex "06272727272727272727272f27272713")
      (def-pico-map-row #:y #x06 #:nonzero-tiles 104 #:sample-hex "06272727272727272727272f27273f13")
      (def-pico-map-row #:y #x07 #:nonzero-tiles 103 #:sample-hex "06272727272727272727272f27272713")
      (def-pico-map-row #:y #x08 #:nonzero-tiles 102 #:sample-hex "06272727272727272727272f27273f13")
      (def-pico-map-row #:y #x09 #:nonzero-tiles 110 #:sample-hex "06272727272727272727272f27272713")
      (def-pico-map-row #:y #x0A #:nonzero-tiles 100 #:sample-hex "0d272727272727272727272f27273f13")
      (def-pico-map-row #:y #x0B #:nonzero-tiles 100 #:sample-hex "0d212727272727272727272f27270c13")
      (def-pico-map-row #:y #x0C #:nonzero-tiles 100 #:sample-hex "0d212727272727272727270c28282839")
      (def-pico-map-row #:y #x0D #:nonzero-tiles 100 #:sample-hex "28282828282829292829292839393939")
      (def-pico-map-row #:y #x0E #:nonzero-tiles 100 #:sample-hex "39393939393939393939393939393939")
      (def-pico-map-row #:y #x0F #:nonzero-tiles 128 #:sample-hex "1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c")
      (def-pico-map-row #:y #x10 #:nonzero-tiles 64 #:sample-hex "13393939393939393939393939393939")
      (def-pico-map-row #:y #x11 #:nonzero-tiles 128 #:sample-hex "0c39393939393939393939393939390c")
      (def-pico-map-row #:y #x12 #:nonzero-tiles 128 #:sample-hex "0d07070739393939393939390707070d")
      (def-pico-map-row #:y #x13 #:nonzero-tiles 128 #:sample-hex "0d07070707393939393939070707070d")
      (def-pico-map-row #:y #x14 #:nonzero-tiles 128 #:sample-hex "0d07070707040404040404070707070d")
      (def-pico-map-row #:y #x15 #:nonzero-tiles 128 #:sample-hex "0d070707071c1c1c1c1c1c070707070d")
      (def-pico-map-row #:y #x16 #:nonzero-tiles 128 #:sample-hex "0d070707073939393939390707070728")
      (def-pico-map-row #:y #x17 #:nonzero-tiles 128 #:sample-hex "06070707070404272704040707070727")
      (def-pico-map-row #:y #x18 #:nonzero-tiles 128 #:sample-hex "0c07070707393917173939070707070c")
      (def-pico-map-row #:y #x19 #:nonzero-tiles 128 #:sample-hex "0d07070707393939393939070707070d")
      (def-pico-map-row #:y #x1A #:nonzero-tiles 128 #:sample-hex "0d07070707040404040404070707070d")
      (def-pico-map-row #:y #x1B #:nonzero-tiles 128 #:sample-hex "0d07070707393939393939070707070d")
      (def-pico-map-row #:y #x1C #:nonzero-tiles 128 #:sample-hex "0d07070717393939393939170707070d")
      (def-pico-map-row #:y #x1D #:nonzero-tiles 128 #:sample-hex "28171717393939393939393917171728")
      (def-pico-map-row #:y #x1E #:nonzero-tiles 128 #:sample-hex "39393939393939393939393939393939")
      (def-pico-map-row #:y #x1F #:nonzero-tiles 128 #:sample-hex "1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c"))
    (sfx-tracks
      (def-pico-sfx #:id #x00 #:editor-mode 14 #:speed 4 #:loop (4 8) #:active-notes 8)
      (def-pico-sfx #:id #x01 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 19)
      (def-pico-sfx #:id #x02 #:editor-mode 3 #:speed 12 #:loop (0 0) #:active-notes 26)
      (def-pico-sfx #:id #x03 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 18)
      (def-pico-sfx #:id #x04 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 22)
      (def-pico-sfx #:id #x05 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id #x06 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 22)
      (def-pico-sfx #:id #x07 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 19)
      (def-pico-sfx #:id #x08 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 19)
      (def-pico-sfx #:id #x09 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x0A #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 24)
      (def-pico-sfx #:id #x0B #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 24)
      (def-pico-sfx #:id #x0C #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 18)
      (def-pico-sfx #:id #x0D #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 26)
      (def-pico-sfx #:id #x0E #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 26)
      (def-pico-sfx #:id #x0F #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x10 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x11 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x12 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x13 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 27)
      (def-pico-sfx #:id #x14 #:editor-mode 9 #:speed 12 #:loop (0 0) #:active-notes 27)
      (def-pico-sfx #:id #x15 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x16 #:editor-mode 3 #:speed 12 #:loop (0 0) #:active-notes 24)
      (def-pico-sfx #:id #x17 #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 30)
      (def-pico-sfx #:id #x18 #:editor-mode 9 #:speed 12 #:loop (0 0) #:active-notes 30)
      (def-pico-sfx #:id #x19 #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 21)
      (def-pico-sfx #:id #x1A #:editor-mode 5 #:speed 12 #:loop (0 0) #:active-notes 20)
      (def-pico-sfx #:id #x1B #:editor-mode 9 #:speed 12 #:loop (0 0) #:active-notes 22)
      (def-pico-sfx #:id #x1C #:editor-mode 1 #:speed 12 #:loop (0 0) #:active-notes 26)
      (def-pico-sfx #:id #x1D #:editor-mode 3 #:speed 12 #:loop (0 0) #:active-notes 22)
      (def-pico-sfx #:id #x1E #:editor-mode 9 #:speed 12 #:loop (0 0) #:active-notes 6)
      (def-pico-sfx #:id #x1F #:editor-mode 9 #:speed 12 #:loop (0 0) #:active-notes 6))
    (music-patterns
      (def-pico-music #:pattern #x00 #:flags 0 #:channels (1 2 50 50))
      (def-pico-music #:pattern #x01 #:flags 0 #:channels (1 2 50 50))
      (def-pico-music #:pattern #x02 #:flags 1 #:channels (3 2 4 50))
      (def-pico-music #:pattern #x03 #:flags 0 #:channels (1 2 5 50))
      (def-pico-music #:pattern #x04 #:flags 0 #:channels (3 2 6 50))
      (def-pico-music #:pattern #x05 #:flags 0 #:channels (3 2 7 8))
      (def-pico-music #:pattern #x06 #:flags 0 #:channels (9 2 10 11))
      (def-pico-music #:pattern #x07 #:flags 0 #:channels (12 2 13 14))
      (def-pico-music #:pattern #x08 #:flags 0 #:channels (9 2 10 11))
      (def-pico-music #:pattern #x09 #:flags 0 #:channels (15 2 16 17))
      (def-pico-music #:pattern #x0A #:flags 0 #:channels (9 2 10 11))
      (def-pico-music #:pattern #x0B #:flags 0 #:channels (12 2 13 14))
      (def-pico-music #:pattern #x0C #:flags 0 #:channels (9 2 10 11))
      (def-pico-music #:pattern #x0D #:flags 0 #:channels (15 2 16 17))
      (def-pico-music #:pattern #x0E #:flags 0 #:channels (18 2 19 20))
      (def-pico-music #:pattern #x0F #:flags 0 #:channels (21 22 23 24))
      (def-pico-music #:pattern #x10 #:flags 0 #:channels (18 2 19 20))
      (def-pico-music #:pattern #x11 #:flags 2 #:channels (25 2 26 27))
      (def-pico-music #:pattern #x17 #:flags 4 #:channels (28 29 30 49))
      (def-pico-music #:pattern #x18 #:flags 1 #:channels (1 66 67 68))
      (def-pico-music #:pattern #x19 #:flags 2 #:channels (3 66 67 68))
      (def-pico-music #:pattern #x20 #:flags 1 #:channels (37 42 67 68))
      (def-pico-music #:pattern #x21 #:flags 2 #:channels (95 66 67 68))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      "--      -- birds with guns --"
      "--by yolwoocle & gouspourd"
      "--extra credits :notgoyome"
      "--music: simon t."
      ""
      "--bird ideas"
      "--crow,owl,raven,pelican,goose,"
      "--colibri,dinosaur,cockatiel"
      "--peafowl"
      ""
      "-- 2023-02-05 stealth patch by"
      "-- zep to fix 0.2.5g breakage"
      "-- (nested comments no longer"
      "-- supported)"
      ""
      "degaplus = 0"
      ""
      "function _init()"
      "\tkeyboard = false"
      "\tinitguns()"
      "\tenemies,checker = {},{}"
      "\t--mouse"
      "\tmx,my=0,0  "
      "\t"
      "\t--flags"
      "\tsolid,breakable,spawnable,lootable,notbulletsolid=0,1,2,3,4"
      "\t"
      "\t--camera"
      "\tshake,camy,camx,targetcamx=0,0,0,0"
      "\t"
      "\tcam_follow_player=true"
      "--\ttrainpal = {{8,2},{11,3},"
      "--\t{7,13},{12,13},{10,9},{0,2}}"
      "\t"
      "\t-- zep:"
      "\ttrainpal = split\"8,2,11,3,7,13,12,13,10,9,0,2,8,2\""
      "\t"
      "\tpal_n,menu = 1,\"main\""
      "\t"
      "\tactors = {}"
      "\tinit_enemies()"
      "\tinit_player(111)"
      "\t"
      "\tinit_ptc()"
      "\twl,diffi = 4,20"
      "\t"
      "\t--wagon length"
      "\twagon_n,trainlen = 0,6"
      "\ttl = trainlen"
      "\t"
      "\tgen_train()"
      "\tupdate_room()"
      "\trandom,enemies = {},{}"
      "\tparcourmap()"
      "\t"
      "\tdrops={}"
      "\t"
      "\tinit_menus()"
      "\t"
      "\tbirdchoice,hardmodetimer=0,0"
      "\tofsetboss,bullets_shooted,bullets_hit = 0,1,1"
      "\t"
      "\tstats={"
      "\t time=0,"
      "\t kills=0,"
      "\t wagon=0,"
      "\t}"
      "\t"
      "\tis_boss = false"
      "\tboss_pos = {0,0}"
      "\twin,wintimer = false,0"
      "\t"
      "\t--darker blue"
      "\t--pal(1,130,1)"
      "\t--pal(1,129,1)"
      "\tpal()"
      "\tpoke(0x5f2e,1)"
      "\t"
      "\tlocal s = stat(6)"
      "\tif s == \"-\""
      "\tor s == \"\" "
      "\tor s == nil then"
      "\t\tmenu=\"main\""
      "\telse"
      "\t\tmenu=\"game\""
      "\t\tbirdchoice=tonum(stat(6))"
      "\t\tbegin_game()"
      "\tend"
      "\t"
      "end"
      ""
      "function _update60()"
      "\tmouse_x_y()"
      "\tfor i=0x3100,0x3148 do"
      "\t\t--on"
      "\t\tpoke(i,peek(i)&0b10111111)"
      "\tend"
      "\t"
      ""
      "\tif hardmodetimer > 90 and "
      "\tmenu == \"main\" and diffi != 17 then"
      "\t\tsfx(44)"
      "\t\tshake,diffi = 5,17"
      "\t\tdegaplus = 1"
      "\t\tinitguns()"
      "\t\tinit_enemies()"
      "\tend"
      ""
      "\tgrasstile()"
      "\tif(win) wintimer += 1"
      "\tif wintimer == 180 then"
      "\t\tmenu=\"win\" "
      "\t\tset_stats()"
      "\tend"
      "\t--if(wintimer==180)sfx(46)"
      "\tif menu == \"game\" then"
      "\t\tdelchecker()"
      "\t\t"
      "\t\tupdate_drops()"
      "\t\tplayer_update()"
      "\t\t"
      "\t\tfor a in all(actors) do"
      "\t\t\t--actors are just bullets"
      "\t\t\ta:update()"
      "\t\t\t"
      "\t\t\tif a.destroy_flag then"
      "\t\t\t\tif a.dmg == 0 then"
      "\t\t\t\t\tanimexplo(a)"
      "\t\t\t\t\tguns.explosion:fire(a.x-a.dx*2,a.y-a.dy*2,1)"
      "\t\t\t\telseif a.dmg == 0.1 then"
      "\t\t\t\t\t--firework launcher"
      "\t\t\t\t\tfor i=1,10 do"
      "\t\t\t\t\t\tsfx(32)"
      "\t\t\t\t\t\tguns.machinegun:shoot(a.x-a.dx*2,a.y-a.dy*2,i/10)"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tdel(actors,a)"
      "\t\t\tend"
      "\t\tend"
      "\t\t"
      "\t\t--for e in all(enemies) do"
      "\t\t\tupdate_enemy(e)"
      "\t\t\t--if(e.destroy_flag)del(enemy,e)"
      "\t\t--end"
      "\t\t"
      "\t\tfor ptc in all(particles) do"
      "\t\t\tupdate_ptc(ptc)"
      "\t\t\tif(ptc.destroy)del(particles,ptc)"
      "\t\tend"
      "\t\t"
      "\t\tupdate_door()"
      "\t\t"
      "\t\t--shake = 0"
      "\t\t"
      "\t\tupdate_camera()"
      "\telseif menus[menu] then"
      "\t\tlocal m = menus[menu]"
      "\t\tm.update(m)"
      "\t\tsprms = 127"
      "\tend"
      "\t"
      "\tshake = max(0,shake-0.3)"
      "\t"
      "\tlocal txt=keyboard and \"keyboard\" or \"mouse+keys\""
      "\tmenuitem(3,\"mode:\"..txt, function() keyboard = not keyboard end)"
      "\tmenuitem(2,\"⌂ main menu\", function() run(\"-\") end)"
      "\t"
      "\tif (btn(❎) or btn(🅾️)) keyboard = true "
      "\tif (lmb) keyboard = false"
      "end"
      ""
      ""
      "function _draw()"
      "\tlocal ox = rrnd(shake)"
      "\tlocal oy = rrnd(shake)"
      "\t--if (keyboard == true) "
      "\tcamera(camx+ox, camy+oy)"
      "\t"
      "\tcls(15)"
      "\t"
      "\t--draw map"
      "\tdrawgrass()"
      "\t"
      "\tdraw_map()"
      "\tif wagon_n==0 and menu==\"game\" then"
      "\t\tlocal s= [["
      "  ⬆️        [e]"
      "⬅️⬇️➡️ or [s d f] "
      "     move "
      ""
      "[click]  shoot"
      "[scroll] change "
      "          weapon"
      "\t\t]]"
      "\t\tif(keyboard)s=[["
      "    ⬆️"
      "  ⬅️⬇️➡️ move "
      ""
      "  ❎ (x) shoot"
      "  🅾️ (c) change "
      "         weapon"
      "\t\t]]"
      "\t\tprint(s,33,42,2)"
      "\tend"
      ""
      "\tdraw_weel()"
      "\t"
      "\tdraw_drops()"
      "\t"
      "\tfor e in all(enemies) do"
      "\t\tdraw_enemy(e)"
      "\tend"
      "\tdraw_player()"
      "\t"
      "\tfor a in all(actors) do"
      "\t\ta:draw()"
      "\tend"
      "\t"
      "\tfor ptc in all(particles) do"
      "\t\tdraw_ptc(ptc)"
      "\tend"
      "\t"
      "\tif(menu!=\"main\")draw_player_ui(p)"
      "\t"
      "\tlocal m = menus[menu]"
      "\tif m then"
      "\t\tm.draw(m)"
      "\tend"
      "\t"
      "\t-->>no code below this<<--"
      "\t--draw mouse"
      "\t"
      "\tif(not keyboard or menu==\"game\")spr(sprms,mx-1,my-1)"
      "\tpal(1,129,1)"
      "end"
      ""
      "----------"
      "function set_stats()"
      "\tstats.time=flr("
      "\t (time()-stats.time) * 10) / 10"
      "\tlocal t = stats.time"
      "\tlocal s = \"\""
      "\tif(t%60 < 10) s=\"0\""
      "\tstats.time= tostr(t\\60)..\":\"..s..tostr(t%60) "
      "\t--stats.time=(flr(stats.time)\\60)+((flr(stats.time)-(flr(stats.time)\\60)*60)/100)"
      "\tstats.wagon=tostr(wagon_n+1)..\"/7\""
      "end"
      ""
      "function begin_game()"
      "\tsfx(37)"
      "\tmusic()"
      "\t"
      "\tlocal b=birdchoice or 0"
      "\tif b == 0 then"
      "\t\tb=flr(rnd(12))+1"
      "\tend"
      "\tinit_player(111+b)"
      "\t"
      "\tstats.time = time()"
      "\t"
      "\tp.x,p.y = 48,56"
      "\t"
      "\tshake += 7"
      "\tfor i=1,10 do"
      "\t\tmake_ptc("
      "\t\t 48 + rrnd(8),"
      "\t\t 56 + rrnd(8),"
      "\t\t 8+rnd(8),rnd({2,4,6}),0.97,"
      "\t\t rrnd(2),rrnd(2)"
      "\t\t)"
      "\tend"
      "end"
      ""
      "function isleft(a)"
      "\treturn a<.75 and .25<a"
      "end"
      ""
      "function ospr(s,x,y,col)"
      "\tfor i=0,15 do"
      "\t\tpal(i,col)"
      "\tend"
      "\t"
      "\tfor i=-1,1do"
      "\t\tfor j=-1,1do"
      "\t\t\tspr(s,x+i,y+j)"
      "\t\tend"
      "\tend"
      "\t"
      "\tpal()"
      "\tspr(s,x,y)"
      "end"
      ""
      "function oprint(t,x,y,col,ocol)"
      "\tlocal ocol = ocol or 1"
      "\tfor i=-1,1do"
      "\t\tfor j=-1,1do"
      "\t\t\tprint(t,x+i,y+j,ocol)"
      "\t\tend"
      "\tend"
      "\t"
      "\tlocal col = col or 7"
      "\tprint(t,x,y,col)"
      "end"
      ""
      "function copy(t)"
      "\tlocal n={}"
      "\tfor k,v in pairs(t) do"
      "\t\tn[k] = v"
      "\tend"
      "\treturn n"
      "end"
      ""
      "function update_camera()"
      "\tlocal px = p.x"
      "\tlocal wl = wl"
      "\tlocal maxlen = 240"
      "\t"
      "\t--poke(0x5f40,0)"
      "\tpoke(0x5f43,0)"
      "\tif px > 128*(wl-1)+8 then"
      "\t\t--pan cam to connector room"
      "\t\tcam_follow_player=false"
      "\t\ttargetcamx=128*(wl-1)"
      "\t\t"
      "\t\t--block off old entrance"
      "\t\tif wagon_n != tl-1 then"
      "\t\t\t--mset(48,7,6)"
      "\t\t\t--mset(48,6,13)"
      "\t\tend"
      "\t\t"
      "\t\t--low-pass filter & slow"
      "\t\t--poke(0x5f40,15)"
      "\t\tif(wagon_n!=tl)poke(0x5f43,15)"
      "\tend"
      "\tif cam_follow_player then "
      "\t\t--camera follows player"
      "\t\tcamx = px-60"
      "\t\t--offset camera to cursor"
      "\t\tif not keyboard then"
      "\t\tcamx += (stat(32)-64)/3"
      "\t\tend"
      "\t\tcamx = mid(0, camx, 128*(wl-2)+8) \\ 1"
      "\t\tcamy = 0"
      "\telse"
      "\t\t--do a cool animation"
      "\t\tcamx=ceil("
      "\t\t camx+(targetcamx-camx)/10)"
      "\t\t"
      "\t\tif targetcamx <= 0"
      "\t\tand ceil(camx)==targetcamx then"
      "\t\t\tcam_follow_player=true"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function draw_ghost_connector()"
      "\tif camx<0 then"
      "\t\tmap(0,16, -128,0, 16,16)"
      "\tend"
      "end"
      ""
      "function rrnd(n)"
      "\t--\"radius rnd\""
      "\treturn rnd(2*n)-n"
      "end"
      ""
      "function allbtn(b)"
      "\treturn btn(b) or btn(b,1)"
      "end"
      ""
      "--[["
      "function debug_()"
      "\tlocal p =players[1]"
      "\tp.gunls[1] = debuggun"
      "\twagon_n = tl-1"
      "\tfor i in all(enemies)do "
      "\t\ti.destory = true"
      "\tend"
      "\tp.maxlife = 10000"
      "\tp.life = 10000"
      "end--]]"
      ""
      "-->8"
      "--player"
      "function init_player(bird)"
      "\tb=0"
      "\tdx1=1"
      "\tdy1=0"
      "\tp = {"
      "\t\tn=1,"
      "\t\tagro = 9999,"
      "\t\tx=-64,y=-64,"
      "\t\tdx=0,dy=0,"
      "\t\ta=0,"
      "\t\t"
      "\t\tspd=.4,"
      "\t\tfric=0.75,"
      "\t\t"
      "\t\tbx=2,by=2,"
      "\t\tbw=4,bh=4,"
      "\t\t"
      "\t\thx=2,hy=2,"
      "\t\thw=4,"
      "\t\t"
      "\t\tlife=10,"
      "\t\tmaxlife=10,"
      "\t\tammo=250,"
      "\t\tmaxammo=250,"
      "\t\t"
      "\t\tspr=bird,"
      "\t\t"
      "\t\tgun=nil,"
      "\t\tgunn=1,"
      "\t\tgunls={},"
      "\t"
      "\t\tlmbp = true,"
      "\t\tiframes=30,"
      "\t\t"
      "\t\tdamage=damage_player,"
      "\t\tspriteoffset = 0,"
      "\t\tkak = copy(kak)"
      "\t}"
      ""
      "\tp.gun = p.gunls[1]"
      ""
      "\t--should we keep this in? bird stats"
      ""
      "\tlocal n = bird-111"
      "\tlocal bird_stats=split[[n,     1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12"
      ",life,   10, 10, 5,  10, 10, 10, 10, 10, 10, 2,  10, 10"
      ",maxlife,10, 10, 5,  10, 10, 10, 10, 10, 10, 15, 10, 10"
      ",spd,    .4, .4, .4, .4, .4, .4, .4, .4, .55, .4, .4, .4"
      ",fric,   .75,.75,.75,.75,.75,.75,.75,.75,.75,.74,.75,.75"
      "]]"
      "\tfor i=1,#bird_stats,13 do"
      "\t\tp[bird_stats[i] ] = bird_stats[i+n]"
      "\tend"
      "\t--                        [    default    ][     pigeon    ][       duck         ][         sparrow            ][          parrot          ][    toucan         ][     flamingo   ][         eagle            ][    seagull       ][      ostrich     ][    penguin  ][      jay           ][     chicken    ] "
      "\tlocal bird_weapons=split\"revolver,shotgun,revolver,shotgun,revolver,flamethrower,boxing_glove,fireworklauncher,machinegun,fireworklauncher,boxing_glove,shotgun,revolver,ringcannon,boxing_glove,assaultrifle,machinegun,sniper,machinegun,gatlinggun,shotgun,sniper,shotgun,assaultrifle,revolver,bazooka\""
      "\t"
      "\tfor i=1,2 do"
      "\t\tp.gunls[i] = copy(guns[bird_weapons[2*n+i] ])"
      "\tend"
      "\t"
      "\tupdate_gun(p)"
      "end"
      ""
      "function player_update()"
      "\t --damage"
      "\t p.iframes = max(0,p.iframes-1)"
      "\t\t--movement"
      "\t\tlocal dx,dy = p.dx,p.dy"
      "\t\tlocal spd = p.spd"
      "\t\t"
      "\t\tif (allbtn(⬅️)) p.dx-=spd dx1-=spd"
      "\t\tif (allbtn(➡️)) p.dx+=spd dx1+=spd"
      "\t\tif (allbtn(⬆️)) p.dy-=spd dy1-=spd"
      "\t\tif (allbtn(⬇️)) p.dy+=spd dy1+=spd"
      "\t\t"
      "\t\t--58"
      "\t\t"
      "\t\tp.dx *= p.fric"
      "\t\tp.dy *= p.fric"
      "\t\t"
      "  if (abs(dx1)+abs(dy1))>0.1 then"
      "\t\tdx1 *= p.fric"
      "\t\tdy1 *= p.fric"
      "\t\tend"
      "\t\t"
      "\t\tcollide(p,0.1)"
      "\t\t"
      "\t\tp.x += p.dx"
      "\t\tp.y += p.dy"
      "\t\t"
      "\t\t"
      "\t\t--animation"
      "\t\t"
      "\t\tif abs(p.dx)+abs(p.dy)>0.75  then"
      "\t\t animplayer(p)"
      "\t\telse "
      "\t\t\tp.spriteoffset = 0"
      "\t\tend"
      "\t\t"
      "\t\t--aiming"
      "\t\tif keyboard then"
      "\t\t\tsprms=76"
      "\t\t\tdistmin=9999"
      "\t\t\tindexmininit={x=p.x-ofsetboss+dx1,y=p.y-ofsetboss+dy1}"
      "\t\t\tindexmin=indexmininit"
      "\t\t\tfor e in all(enemies) do"
      "\t\t\t \tif loaded(e) and "
      "\t\t\t \tcanshoot(p,e) then"
      "\t\t\t\t\tlocal dist = dist(p,e)"
      "\t\t\t\t\tif (distmin>dist) distmin=dist indexmin=e"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\tofsetboss = 0"
      "\t\t\tif(indexmin.spr == 1) ofsetboss = 4"
      ""
      "\t\t\tp.a = atan2(indexmin.x+ofsetboss-p.x,"
      "\t\t\tindexmin.y+ofsetboss-p.y)"
      "\t\t\tmx=indexmin.x+1+ofsetboss"
      "\t\t\tmy=indexmin.y+1+ofsetboss"
      "\t\t\tif(indexmin==indexmininit)sprms=57"
      "\t\telse"
      "\t\t\tsprms = 127"
      "\t\t\tp.a = atan2(mx-p.x,"
      "\t\t\tmy-p.y)\t"
      "\t\tend"
      "\t\tp.flip = isleft(p.a)"
      "\t\t"
      "\t\t--ammo & life"
      "\t\tp.life=min(max(0,p.life),p.maxlife)"
      "\t\tp.gun.ammo=min(max(0,p.gun.ammo),p.gun.maxammo)"
      "\t\t"
      "\t\t--death"
      "\t\tif p.life <= 0 "
      "\t\tand menu!=\"death\"then"
      "\t\t\tsfx(34)"
      "\t\t\tmusic(-1, 300)"
      "\t\t\t"
      "\t\t\tmenu = \"death\""
      "\t\t\tshake += 9"
      "\t\t\tburst_ptc(p.x+4,p.y+4,7)"
      "\t\t\t"
      "\t\t\tset_stats()"
      "\t\tend"
      "\t\t"
      "\t\t--shooting"
      "\t\tif stat(36) ==1 or stat(36) ==-1 or (btnp(🅾️)) then"
      "\t\t\tnextgun(p)"
      "\t\t\t--print(p.gun.cooldown,0,0)"
      "\t\t\tp.gun.timer = p.gun.cooldown/2"
      "\t\tend"
      "\t\t"
      "\t\t"
      "\t\tlocal fire=lmb or btn(❎) "
      "\t\tlocal active=rmb"
      "\t\t"
      "\t\tlocal dofire"
      "\t\t"
      "\t\tp.kak:update()"
      "\t\tp.gun:update()"
      "\t\ttest = p.gun.name"
      "\t\t-- not auto"
      "\t\tif fire and"
      "\t\tp.gun.timer<=0 and"
      "\t\tp.gun.ammo > 0 and p.gun.auto == false"
      "\t\tthen"
      "\t\t\tif p.lmbp == true then"
      "\t\t\t\tdofire = true"
      "\t\t\t\t"
      "\t\t\t\tp.lmbp = false"
      "\t\t\tend"
      "\t\t\t"
      "\t\t-- auto"
      "\t\telseif fire and p.gun.timer<=0 "
      "\t\tand p.gun.ammo > 0 then"
      "\t\t\tdofire = true"
      "\t\telseif fire and"
      "        p.gun.ammo < 1 and"
      "        p.lmbp == true and"
      "        p.kak.timer<=0 then"
      "        coupdekak(p) "
      "        p.lmbp = false"
      "\t\tend"
      "\t\t"
      "\t\tif dofire then"
      "\t\t\tmake_ptc(p.x+cos(p.a)*6+4, "
      "\t\t\t\tp.y+sin(p.a)*3+4, rnd(3)+6,7,.7)"
      "\t\t\t\t"
      "\t\t\tp.gun.ammo -= 1"
      "\t\t\tp.gun:fire(p.x+4,p.y+4,p.a)"
      "\t\tend"
      "\t\t"
      "\t\t-- if mleft not pressed "
      "\t\tif not fire then"
      "\t\t\tp.lmbp = true"
      "\t\tend"
      "\t\t"
      "\t\t--begin boss"
      "\t\tlocal w3=128*(wl-1)"
      "\t\t"
      "\t\tif wagon_n==tl and p.x>w3 "
      "\t\tand cam_follow_player "
      "\t\tand not is_boss then"
      "\t\t\tis_boss = true"
      "\t\t\tbegin_boss()"
      "\t\t\tp.x = w3+8"
      "\t\tend"
      "\t\t"
      "\t\t--next wagon"
      "\t\tif p.x>128*wl then"
      "\t\t\trandom = {}"
      "\t\t\t"
      "\t\t\twagon_n += 1"
      "\t\t\tupdate_room()"
      "\t\t\tenemiescleared=false"
      "\t\t\tpal_n += 1"
      "\t\t\t"
      "\t\t\t--pan cam to next wagon"
      "\t\t\tcamx = -128"
      "\t\t\ttargetcamx=0"
      "\t\t\tdrops = {}"
      "\t\t\tenemies = {}"
      "\t\t\tparcourmap()"
      "\t\t\t--teleport players"
      "\t\t\tp.x -= 128*wl"
      "\t\t\tp.x = max(p.x, 0)"
      "\t\tend"
      "\t\tfor e in all(enemies)do"
      "\t\t\t"
      "\t\t\tif touches_rect("
      "\t\t\tp.x+4,p.y+4,"
      "\t\t\te.x+1,e.y+1,e.x+7,e.y+7) then"
      "\t\t\t\t"
      "\t\t\t\tif (p.iframes == 0) then"
      "\t\t\t\t\tsfx(35)"
      "\t\t\t\t\tif(shake<=2)shake += 2"
      "\t\t\t\t\tif e.spr != 126 then"
      "\t\t\t\t\t\tp.life-=1+(degaplus*2)"
      "\t\t\t\t\telse "
      "\t\t\t\t\t\tp.life-=1+degaplus"
      "\t\t\t\t\tend"
      "\t\t\t\t\tp.iframes = 30"
      "\t\t\t\t\t"
      "\t\t\t\t\tif e.spr == 109 then"
      "\t\t\t\t\t p.life+=1"
      "\t\t\t\t\t killbarelle(e)"
      "\t\t\t\t\t p.iframes = 0"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tknockback_player(p,e)"
      "\t\t\t"
      "\t\t\tend"
      "\t\tend"
      "end"
      ""
      "function draw_player()"
      "\tif (p.iframes%5) == 0  then"
      "\t\tlocal x=flr(p.x) + cos(p.a)*6 +0"
      "\t\tlocal y=flr(p.y) + sin(p.a)*3 +0"
      "\t\t"
      "\t\tif p.gun.name==\"sniper\" then"
      "\t\t\tlocal c,s=cos(p.a),sin(p.a)"
      "\t\t\tline("
      "\t\t\tx+4+c*6,"
      "\t\t\ty+4+s*6,"
      "\t\t\tp.x+c*128,"
      "\t\t\tp.y+s*128,8)"
      "\t\tend"
      "\t\tspr(p.gun.spr,x,y,1,1, p.flip)"
      "\t\t"
      "\t\t"
      "\t\tpalt(0,false)"
      "\t\tpalt(1,true)"
      "\t\t"
      "\t\tspr(p.spr,p.x,p.y+p.spriteoffset,1,1, p.flip)"
      "\t\t"
      "\t\tpalt()"
      "\tend"
      "end"
      ""
      "function draw_player_ui(p)"
      "\t--life counter"
      "\trectfill(camx+1,1,camx+43,7,2)"
      "\tlocal l=40*(p.life/p.maxlife)"
      "\trectfill(camx+2,2,camx+2+l,6,8)"
      "\t"
      "\tlocal s=\"♥\"..p.life..\"/\"..p.maxlife..\" \""
      "\tprint(s, camx+2,2,7)"
      "\t"
      "\t--ammo bar"
      "\trectfill(camx+84,1,camx+84+42,7,4)"
      "\tlocal l=40*(p.gun.ammo/p.gun.maxammo)"
      "\tif(p.ammo>0)rectfill(camx+85,2,camx+85+l,6,9)"
      "\t"
      "\tlocal s,col = tostr(p.gun.ammo),7"
      "\tif(s==\"0\") s,col=\"no ammo!\",14"
      "\tspr(110,camx+89,2)"
      "\tprint(s, camx+95,2,col)"
      "\t"
      "\t--weapon list"
      "\tfor i=1,2 do"
      "\t\tlocal col = 1"
      "\t\tif(i==p.gunn)col=7"
      "\t\t"
      "\t\tospr(p.gunls[i].spr, "
      "\t\tcamx+90+(i-1)*10, 10,col)"
      "\tend"
      "\t"
      "\t--wagon"
      "\tlocal color = 7"
      "\tif degaplus == 1 then"
      "\t\tcolor = 8"
      "\t\telse color = 7"
      "\tend"
      "\toprint(\"wagon \"..wagon_n+1 ..\"/7\","
      "\tcamx+46,2,color,1)"
      "\t--print(test,0,80)"
      "end"
      ""
      "function nextgun(p)"
      "\tsfx(36)"
      "\t"
      "\tp.gunn += 1"
      "\tif(p.gunn > #p.gunls) p.gunn = 1"
      "\tupdate_gun(p)"
      "\t--[[local f = 0"
      "\tfor i=1,#p.gunls do"
      "\tif p.gunls[i] == p.gunn then"
      "\t\tif (((i+stat(36))%#p.gunls)<1) f = #p.gunls"
      "\t\t return p.gunls[(i+stat(36))%(#p.gunls)+f]"
      "\t\tend"
      "\tend]]"
      "end"
      ""
      "function update_gun(p)"
      "\tp.gun = p.gunls[p.gunn]"
      "end"
      ""
      "function knockback_player(p,e)"
      "\tif abs(p.dx)+abs(p.dy) < 3 then"
      "\t\t\t  p.dx+=e.dx*e.spd*2"
      "\t\t\t\t p.dy+=e.dy*e.spd*2"
      "\t\t\tend\t"
      "end"
      ""
      "function knockback_enemy(e,b)"
      "\t"
      "\t\tif (abs(e.dx)+abs(e.dy<30)) then"
      "\t\t\te.dx+=b.dx*b.spd*.1"
      "\t\t\te.dy+=b.dy*b.spd*.1"
      "\t\tend"
      ""
      "end"
      ""
      "function animplayer(p)"
      "\tif flr(time()*7)%2==1 then"
      "\t\tp.spriteoffset = 1"
      "\telse "
      "\t\tp.spriteoffset = 0"
      "\tend"
      "end"
      ""
      "function coupdekak(p)"
      "\tlocal x=flr(p.x) + cos(p.a)*6 +0"
      "\tlocal y=flr(p.y) + sin(p.a)*3 +0"
      "\t"
      "\tp.kak:fire(x+4,y+4,p.a)"
      "end"
      "-->8"
      "--gun & bullet"
      ""
      "function make_gun(args,fire)"
      "\tlocal name_,sprr,cd_,spd,oa,dmg,is_enemy,auto,maxammo,sfxx,knockback=unpack(split(args))"
      ""
      "\t"
      "\tis_enemy = is_enemy == 1"
      "\tauto = auto  == 1"
      "\tif(is_enemy) dmg += degaplus * 2"
      "\t"
      "\t--todo:not have 3000 args"
      "\tlocal gun = {"
      "\t\tname=name_,"
      "\t\tspr=sprr,"
      "\t\tspd=spd,"
      "\t\toa=oa,--offset angle in [0,1["
      "\t\tdmg=dmg,"
      "\t\tshake=shake,"
      "\t\tauto=auto,"
      "\t\t"
      "\t\tammo=maxammo,"
      "\t\tmaxammo=maxammo,"
      "\t\t"
      "\t\ttimer=0,"
      "\t\tcooldown=cd_,"
      "\t\tis_enemy=is_enemy,"
      "\t\t"
      "\t\tx=0,y=0,"
      "\t\tdir=0,"
      "\t\tburst=0,"
      "\t\t"
      "\t\tsfx=sfxx,"
      "\t\tknockback=knockback,"
      "\t}"
      "\t"
      "\tgun.fire = fire"
      "\t"
      "\tgun.shoot=function(gun,x,y,dir,spd,knockback)"
      "\t\t--remove? it complicates code"
      "\t\tif(gun.burst<=0)dir+=rrnd(gun.oa)"
      "\t\t"
      "\t\tif(gun.sfx) sfx(gun.sfx)"
      "\t\t"
      "\t\tlocal s=93"
      "\t\tlocal name = gun.name"
      "\t\tlocal palette = \"\""
      ""
      "\t\tif(gun.is_enemy)s=95"
      "\t\tif(name==\"kak\")s=77 lifspa=5"
      "\t\tif(name==\"boxing glove\")s,lifspa=77,10"
      "\t\tif(name==\"flamethrower\") lifspa=40 palette=\"1,2,3,4,5,6,10,8,8,9\""
      "\t\tif(name==\"explosion\")s=57 lifspa=10"
      "\t\tif(name==\"bazooka\") palette=\"1,2,3,4,5,6,6,8,5,13\""
      "\t\tif not gun.is_enemy then"
      "\t\t\tif(shake<1 and name!=\"flamethrower\")shake+=1 "
      "\t\tend"
      "\t\t"
      "\t\tspd = spd or gun.spd"
      "\t\tspawn_bullet(x,y,dir,"
      "\t\tspd,3,s,dmg,is_enemy,lifspa,palette)"
      "\t\tlifspa=nil"
      "\t\tgun.timer = gun.cooldown"
      "\t\tp.dx-=cos(dir)*gun.knockback"
      "\t\tp.dy-=sin(dir)*gun.knockback"
      "\tend"
      "\t"
      "\tgun.update=function(gun)"
      "\t\tgun.timer = max(gun.timer-1,0)"
      "\t\tgun.ammo = mid(0,gun.ammo,gun.maxammo)"
      "\t\t"
      "\t\tif gun.burst > 0 then"
      "\t\t\tgun:shoot(gun.x,gun.y,gun.dir)"
      "\t\t\tgun.burst -= 1"
      "\t\tend"
      "\tend"
      "\t"
      "\treturn gun"
      "end"
      ""
      "function shoot1(gun,x,y,dir)"
      "\tgun:shoot(x,y,dir)"
      "end"
      ""
      "-- init guns"
      ""
      "--degaplus = 0"
      "                   --name      spr cd spd oa dmg is_enemy auto maxammo sfx knock"
      "--debuggun = make_gun(\"debuggun, 64, 1, 3, .02, 0, 0,       1,   999999, 64, 1\","
      "--\t\tfunction(gun,x,y,dir)"
      "--\t  for i=1,7 do"
      "--\t \t\tp.life += 1"
      "--\t \t\tgun:shoot(x,y,dir+rrnd(.1), ospd)"
      "--\t \tend"
      "--end"
      "--\t\tfunction(gun,x,y,dir)"
      "--\t\t\tgun:shoot(x,y,dir)"
      "--\t\tend"
      "--\t)"
      "function initguns()"
      "guns = {"
      ""
      "                       --name   spr cd spd oa dmg is_enemy auto maxammo sfx"
      "\trevolver = make_gun(\"revolver, 64, 15,2.5,.02,3 ,0,       0,   100,    33, 0.3\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\t"
      "\tfireworklauncher = make_gun(\"firework launcher, 74, 25,2.5,.02,0.1 ,0,       0,   80,    52, 0.6\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\tboxing_glove = make_gun(\"boxing glove, 72, 18,3.3,.005,1 , 0, 0, 1,      53, -0.96\","
      " function(gun,x,y,dir)"
      "  for i=1,7 do"
      "\t\t\tgun:shoot(x,y,dir)"
      "\t\tend"
      "\t\tp.iframes,gun.ammo = 9,gun.maxammo"
      "\t\tend"
      " ),"
      "\t"
      "\t"
      "\tbazooka = make_gun(\"bazooka, 69, 90,1.5,.007,0 ,0,       0,   20,    33, 4.5\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\tflamethrower = make_gun(\"flamethrower, 70, 2,1.5,.015,0.34 ,0,       1,   1500,    51, 0\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\tringcannon = make_gun(\"ring cannon,    71, 45,2, .01,3,  0,   0,  50,    32, 0\","
      "\t function(gun,x,y,dir)"
      "\t \tfor i=1,20 do"
      "\t \t\tlocal o=i/20"
      "\t \t\tlocal ospd=gun.spd*(rnd(.2)+.9)"
      "\t \t\tgun:shoot(x,y,dir+o, ospd)"
      "\t \tend"
      "\t end),"
      "\t                    --name    spr cd spd oa dmg is_enemy auto maxammo sfx"
      "\tshotgun = make_gun(\"shotgun,    65, 60,4, .05,1.25,  0,   0,  50,    32, 0.4\","
      "\t function(gun,x,y,dir)"
      "\t \tfor i=1,7 do"
      "\t \t\tlocal o=rrnd(.05)"
      "\t \t\tlocal ospd=gun.spd*(rnd(.2)+.9)"
      "\t \t\tgun:shoot(x,y,dir+o, ospd)"
      "\t \tend"
      "\t end),"
      "\t "
      "\t                         --name      spr cd spd oa dmg is_enemy auto maxammo sfx"
      "\tmachinegun = make_gun(\"machinegun, 66, 7, 3, .05,2  ,0,       1, 250,    33, .2\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\t                          --name           spr cd spd oa dmg is_enemy auto maxammo sfx"
      "\tassaultrifle = make_gun(\"assault rifle, 67, 30,4, .02,1   ,0,       1, 75,      33, .3\","
      "\t\tfunction(gun,x,y,dir)"
      "\t\t\tgun.burst = 4"
      "\t\t\tgun.x, gun.y = x, y"
      "\t\t\tgun.dir =dir+(rrnd(1))*gun.oa"
      "\t\t\tgun:shoot(x,y,gun.dir)"
      "\t\tend"
      "\t),"
      "\t"
      "\t                   --name  spr cd spd oa dmg is_enemy auto maxammo sfx"
      "\tsniper = make_gun(\"sniper, 68, 40,7, .0, 5  ,0,        0,  35,     32, 3\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\t                            --name  spr cd spd oa dmg is_enemy auto maxammo sfx   kb"
      "\tgatlinggun = make_gun(\"gatling gun, 73, 3, 3, .08, 2  ,0,        1,  500,     33, 1\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\t                      --name      spr cd  spd oa   dmg is_enemy auto maxammo sfx kb"
      "\tgunslime = make_gun(\"gunslime, 64, 100,1.5, .02,2,  1,       1,   250,    32, 0\","
      "\t\tfunction(gun,x,y,dir)"
      "\t\t\tdir+=rrnd(gun.oa)"
      "\t\t\tgun:shoot(x,y,dir)"
      "\t\tend"
      "\t),"
      "\t"
      "                              --name      spr cd spd   oa dmg is_enemy auto maxammo sfx"
      "\tgunslimebuff = make_gun(\"gunslimebuff, 64, 100,1, .04,2,  1,       1,   250, 32, 0\","
      "\t\tfunction(gun,x,y,dir)"
      "\t\t\tfor i=0,2 do"
      "\t\t\t\tlocal o=rrnd(.05)"
      "\t\t\t\tlocal ospd=gun.spd*(rnd(.2)+.9)"
      "\t\t\t\tgun:shoot(x,y,dir+o, ospd)"
      "\t\t\tend"
      "\t\tend"
      "\t),"
      "\t"
      "\t"
      "\tshotgunmechant = make_gun(\"shotgunmechant, 65, 60,1.35, .04,3, 1, 1, 250, 32, 0\","
      "\t\tfunction(gun,x,y,dir)"
      "\t \t\tfor i=1,4 do"
      "\t \t\t\tlocal o=rrnd(.05)"
      "\t \t\t\tlocal ospd=gun.spd*(rnd(.2)+.9)"
      "\t \t\t\tgun:shoot(x,y,dir+o, ospd)"
      "\t \t\tend"
      "\t\tend"
      "\t),"
      "\t "
      "\t null = make_gun(\"null, 57, 0,57, 0,1,  1,  1, 250, 32,0\","
      "\t function() --opti: remove args"
      "\t end),"
      "\t "
      "\t machinegunmechant = make_gun(\"machinegunmechant, 66, 5, .75,.05,2, 1, 1,250, 32, 0\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\texplosion = make_gun(\"explosion, 57, 0, 2,  0,5   ,1,  0, 1, 32, 0\","
      "\t\tfunction(gun,x,y,dir)"
      ""
      "\t\t\tfor i=1,12 do"
      "\t \t\tlocal o=i/12"
      "\t \t\tgun:shoot(x,y,dir+o)"
      ""
      "\t \tend"
      "\tend"
      ""
      "\t),"
      "\t"
      "\tboss_targetgun = "
      "\tmake_gun(\"boss target gun, 65, 6, 1.2,.05,2, 1,  1, 250, 47, 0\","
      "\t\tshoot1"
      "\t),"
      "\t"
      "\tboss_360gun = "
      "\tmake_gun(\"boss 360 gun, 65, 1, 1,  0,2  ,1,  1,\t250,    47, 0\","
      "\t\tfunction(gun,x,y,dir)"
      "\t\t\tgun.dir+=.176666"
      "\t\t\tgun:shoot(x,y,gun.dir)"
      "\t\tend"
      "\t),"
      "\t"
      "\tboss_enemygun = "
      "\tmake_gun(\"boss_enemygun, 65, 150, 1, 1,2   ,1,  1, 250, 33, 0\","
      "\t\tfunction(gun,x,y,dir)"
      "\t\t\tsfx(33)"
      "\t\t\tgun.timer = gun.cooldown"
      "\t\t\tif(rnd(2)<1)return spawn_enemy(x,y,enemy.hedgehog)"
      "\t\t\tspawn_enemy(x,y,enemy.hedgehogbuff)"
      "\t\tend"
      "\t),"
      "}"
      "\t--table of number-indexed guns"
      "\tiguns={}"
      "\tfor k,v in pairs(guns)do"
      "\t\tif(not v.is_enemy)add(iguns,v)"
      "\tend"
      "end"
      ""
      "kak = make_gun(\"kak, 57, 20,2.1,.005,3 , 0, 0, 0,      36, 1\","
      "\tshoot1"
      ")"
      ""
      ""
      "function rnd_gun()"
      "\t--todo: \"power\" param"
      "\t--later weapons should be  "
      "\t--more powerful"
      "\treturn rnd(iguns)"
      "end"
      ""
      "function spawn_bullet(x,y,dir,spd,r,spr,dmg,is_enemy,lifspa,palette)"
      "\tlocal dx=cos(dir)*spd"
      "\tlocal dy=sin(dir)*spd"
      "\tadd(actors,{"
      "\t\tx=x,  y=y,"
      "\t\tdx=dx,dy=dy,"
      "\t\tr=4,"
      "\t\tdmg=dmg,"
      "\t\tspd=spd,"
      "\t\tspr=spr,"
      "\t\tis_enemy=is_enemy,"
      "\t\tdestroy_flag=false,"
      "\t\tdir=dir,"
      "\t\t"
      "\t\tupdate=update_bullet,"
      "\t\tdraw=draw_bullet,"
      "\t\tlifspa=lifspa,"
      ""
      "\t\tpalette=palette,"
      "\t})"
      "end"
      ""
      "function update_bullet(b)"
      " if not(b.lifspa== nil)then"
      "  b.lifspa-=1"
      "  if (b.lifspa== 0) b.destroy_flag = true"
      " end"
      "\tb.x += b.dx"
      "\tb.y += b.dy"
      "\t"
      "\tlocal bx,by = b.x,b.y "
      ""
      "\tdebug=\"\""
      "\tif b.is_enemy then"
      "\t\t"
      "\t\tlocal x2 = p.x+p.hx+p.hw"
      "\t\tlocal y2 = p.y+p.hx+p.hw "
      "\t\tif touches_rect(bx,by,"
      "\t\tp.x+p.hx, p.y+p.hy,"
      "\t\tx2,y2) then"
      "\t\t\t"
      "\t\t\tif p.iframes == 0 then"
      "\t\t\t\tp.life-=b.dmg "
      "\t\t\t\tp.iframes = 30"
      "\t\t\t\tsfx(35)"
      "\t\t\tend"
      "\t\t\tif(shake<=4)shake += 4"
      "\t\t\tknockback_player(p,b)"
      "\t\t\tmake_ptc(bx,by,rnd(4)+6,7,.8)"
      "\t\t\tb.destroy_flag = true"
      "\t\t\t"
      "\t\tend"
      "\tend"
      "\t\t"
      "\tif not(b.is_enemy) or b.spr == 57 then"
      "\t\t"
      "\t\tfor e in all(enemies)do"
      "\t\t if loaded(e) then"
      "\t\t\tlocal x2 = e.x+e.hx+e.hw"
      "\t\t\tlocal y2 = e.y+e.hx+e.hw "
      "\t\t\t"
      "\t\t\tif touches_rect(bx,by,"
      "\t\t\te.x+e.hx,e.y+e.hy,"
      "\t\t\tx2,y2) then"
      "\t\t\t\t"
      "\t\t\t\tsfx(46)"
      "\t\t\t\te.life -= b.dmg"
      "\t\t\t\tif e.life<=0 then"
      "\t\t\t\t\t--kill enemy"
      "\t\t\t\t\tstats.kills+=1 del(enemies,e)"
      "\t\t\t\t\tspawn_loot(e.x,e.y)"
      "\t\t\t\t\tif e.spr != 109 then"
      "\t\t\t\t\tburst_ptc(e.x+4,e.y+4,8,1,1,1)"
      "\t\t\t\t\t"
      "\t\t\t\t\t--boss death"
      "\t\t\t\t\tif e.spr==1 then"
      "\t\t\t\t\t\tshake += 10"
      "\t\t\t\t\t\tboss_pos = {e.x,e.y,e.flip}"
      "\t\t\t\t\t\tmenu = \"bossdeath\""
      "\t\t\t\t\tend"
      "\t\t\t\t\t"
      "\t\t\t\t\telse --animation explosion"
      "\t\t\t\t\t\tkillbarelle(e)"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tbullets_hit+=1"
      "\t\t\t\t"
      "\t\t\t\tknockback_enemy(e,b)"
      "\t\t\t\t"
      "\t\t\t\te.timer = 5"
      "\t\t\t\tmake_ptc(bx,by,rnd(4)+6,7,.8)"
      "\t\t\t\tb.destroy_flag = true"
      "\t\t\t\treturn"
      "\t\t\tend"
      "\t\tend"
      "\t\tend"
      "\tend"
      "\t"
      "\t--destroy on collision"
      "\tif (is_solid(bx,by)"
      "\tand not check_flag("
      "\t    notbulletsolid,bx,by)) "
      "\tor bx+11<camx "
      "\tor bx>camx+139 "
      "\tor by<-8 or by>132"
      "\tthen"
      "\t\t"
      "\t\tif check_flag(breakable,bx,by) then"
      "\t\t\t--sfx(47)"
      "\t\t\tif check_flag(lootable,bx,by)then"
      "\t\t\t\tbreak_crate(bx,by)"
      "\t\t\tend"
      "\t\t\tmset(bx\\8,by\\8,39)"
      "\t\t\tadd(random,{"
      "\t\t\t x=(bx\\8)*8+4,"
      "\t\t\t y=(by\\8)*8+4,"
      "\t\t\t spr=rnd{55,22,39},"
      "\t\t\t f=rnd{true,false},"
      "\t\t\t r=rnd{true,false}"
      "\t\t\t})"
      "\t\tend"
      "\t\tmake_ptc(bx,by,rnd(4)+6,7,.8)"
      "\t\t\t"
      "\t\tb.destroy_flag = true"
      "\tend"
      "end"
      ""
      "function draw_bullet(b)"
      "\tpal(split(b.palette))"
      "\tspr(b.spr, b.x-4, b.y-4,1,1, p.flip)"
      "\tpal()"
      "end"
      ""
      "function draw_random()"
      "for i in all(random)do"
      "\t spr(i.spr, i.x-4, i.y-4,1,1,i.f,i.r)"
      "\tend"
      "end"
      ""
      "function killbarelle(e)"
      " animexplo(e)"
      "\te.gun:fire(e.x+4,e.y+4,e.a)"
      "\tdel(enemies,e)"
      "end"
      ""
      "function animexplo(e)"
      "for i=1,15 do"
      "\t\tmake_ptc("
      "\t\t\t\t\te.x + rrnd(14),"
      "\t\t\t\t\te.y + rrnd(14),"
      "\t\t\t8+rnd(8),rnd{9,10})"
      "\tend"
      "sfx(37)"
      "shake += 7"
      "end"
      ""
      "--------"
      ""
      "--[["
      "function spawn_bullet(x,y,type_bullet,speed,timer_bullet1,sprite,nb_bullet,ecartement)"
      "\tif timer_bullet == 0 then"
      "\t\tlocal xy = get_traj(x,y,mouse_x,mouse_y)"
      "\t\tlocal traj_x = xy.x*speed"
      "\t\tlocal traj_y = xy.y*speed"
      "\t\tlocal angle = xy.angle"
      "\t\ttimer_bullet = timer_bullet1"
      "\t\t"
      "\t\tif type_bullet == 1 then"
      "\t\t\tnvelement = {"
      "\t\t\t  x=x,y=y,"
      "\t\t\t  type_bullet=type_bullet,"
      "\t\t\t  traj_x=traj_x,"
      "\t\t\t  traj_y=traj_y,"
      "\t\t\t  sprite=sprite"
      "\t\t\t}"
      "\t\t\trafale(10,nvelement)"
      "\t\tend"
      "\t "
      "\t if type_bullet == 2 then"
      "\t  for i=0,nb_bullet do"
      "\t   if nb_bullet == 0 then"
      "\t    add(bullet,{"
      "\t      x=x,y=y,"
      "\t      type_bullet=type_bullet,"
      "\t      traj_x=traj_x,"
      "\t      traj_y=traj_y,"
      "\t      sprite=sprite"
      "\t    })"
      "\t\t\t\telse "
      "\t\t\t\t\tadd(bullet,{"
      "\t\t\t\t\t  x=x,y=y,"
      "\t\t\t\t\t  type_bullet=type_bullet,"
      "\t\t\t\t\t  traj_x=cos((angle-((1/ecartement)/2)+(i/nb_bullet)/ecartement))*speed,"
      "\t\t\t\t\t  traj_y=sin((angle-((1/ecartement)/2)+(i/nb_bullet)/ecartement))*speed,"
      "\t\t\t\t\t  sprite=sprite"
      "\t\t\t\t\t})"
      "\t   end"
      "\t  end"
      "\t end"
      " end"
      "end"
      ""
      "-- -(i/2)+i/nb_bullet"
      "function update_bullet()"
      " if (timer_bullet>0)timer_bullet-=1"
      "\tfor i in all(bullet) do"
      "\t\tif is_solid(i.x+(i.traj_x*1.5)+4,i.y+4+(i.traj_y*1.5)) then"
      "\t\t del(bullet,i)"
      "\t end"
      "\t\ti.x += i.traj_x"
      "\t\ti.y += i.traj_y"
      "\tend"
      "end"
      ""
      "function draw_bullet()"
      "\tfor i in all(bullet) do"
      "\t\tspr(i.sprite,i.x,i.y)"
      "\tend"
      "end"
      ""
      "function rafale(nb,bullet)"
      " add(rafalels,{nb=nb,bullet=bullet})"
      "end"
      ""
      "function updaterafale()\t"
      "\tfor i in all(rafalels) do"
      "  if (i.nb<1) del(rafalels,i)"
      "  add(bullet,i.bullet)"
      "  i.nb -=1"
      "\tend"
      "end"
      "--]]"
      "-->8"
      "--mouse"
      "function mouse_x_y()"
      "\tpoke(0x5f2d, 1)"
      "\tmx=stat(32)+flr(camx)"
      "\tmy=stat(33)"
      "\tlocal s = stat(34)"
      "\tlmb=s&1 > 0"
      "\trmb=s&2 > 0"
      "end"
      ""
      ""
      ""
      ""
      "--[[function get_traj(x_satr,y_start,x_end,y_end)"
      "\tangle=atan2(x_end-x_satr-4, "
      "\t y_end-y_start-4)"
      "\treturn {x=cos(angle),"
      "\t y=sin(angle),angle=angle}"
      "end]]"
      ""
      "function check_flag(flag,x,y)"
      "\treturn fget(mget((x\\8),(y\\8)),flag)"
      "end"
      ""
      "-->8"
      "--collision"
      "function is_solid(x,y)"
      "\tif(x<0)return true "
      "\treturn check_flag(0,x,y)"
      "end"
      ""
      "function touches_rect(x,y,x1,y1,x2,y2)"
      "\treturn x1 <= x"
      "\t   and x2 >= x"
      "\t   and y1 <= y"
      "\t   and y2 >= y"
      "end"
      "--[["
      "function circ_coll(a,b)"
      "\t--https://www.lexaloffle.com/bbs/?tid=28999"
      "\t--b: bullet"
      "\tlocal dx=a.x+4 - b.x"
      "\tlocal dy=a.y+4 - b.y"
      "\tlocal d = max(dx,dy)"
      "\tdx /= d"
      "\tdy /= d"
      "\tlocal sr = (a.r+b.r)/d"
      "\t"
      "\treturn dx*dx+dy*dy < sr*sr "
      "end"
      "--]]"
      ""
      "function rect_overlap(a1,a2,b1,b2)"
      "\t--[[return not (a1.x>b2.x"
      "\t         or a1.y>b2.y "
      "\t         or a2.x<b1.x"
      "\t         or a2.y<b1.y)--]]"
      "\t"
      "\treturn a1.x<b2.x"
      "\t   and a1.y<b2.y "
      "\t   and a2.x>b1.x"
      "\t   and a2.y>b1.y--]]"
      "end"
      ""
      "function collision(x,y,w,h,flag)"
      "\treturn "
      "\t   is_solid(x,  y)"
      "\tor is_solid(x+w,y)"
      "\tor is_solid(x,  y+h)"
      "\tor is_solid(x+w,y+h) "
      "end"
      ""
      "function collide(o,bounce1)"
      "\tlocal x,y = o.x,o.y"
      "\tlocal dx,dy = o.dx,o.dy"
      "\tlocal w,h = o.bw,o.bh"
      "\tlocal ox,oy = x+o.bx,y+o.by"
      "\tlocal bounce = bounce1"
      "\t"
      "\t--collisions"
      "\tlocal we,he = w-1, h-1"
      "\tlocal coll_x = collision( "
      "\tox+dx, oy,    we, he)"
      "\tlocal coll_y = collision("
      "\tox,    oy+dy, we, he)"
      "\tlocal coll_xy = collision("
      "\tox+dx, oy+dy, we, he)"
      "\t"
      "\tif coll_x then"
      "\t\to.dx *= -bounce"
      "\tend"
      "\t"
      "\tif coll_y then"
      "\t\to.dy *= -bounce"
      "\tend"
      "\t"
      "\tif coll_xy and "
      "\tnot coll_x and not coll_y then"
      "\t\t--prevent stuck in corners "
      "\t\to.dx *= -bounce"
      "\t\to.dy *= -bounce"
      "\tend"
      "end"
      "-->8"
      "--map "
      "test = 0"
      "wagon_n = 0"
      ""
      "function gen_train()"
      "\t--gen talbe of all wagon nums"
      "\tnums = {}"
      "\tfor i=10,29 do"
      "\t\tadd(nums,i)"
      "\tend"
      "\t"
      "\t--gen train"
      "\ttrain = {[0]=9}"
      "\t"
      "\tfor i=0,tl do"
      "\t\tlocal w = i*wl"
      "\t\tfor j=0,2 do"
      "\t\t\t"
      "\t\t\tlocal n = 10+flr(rnd(21))"
      "\t\t\tif(#nums>0)n=nums[flr(rnd(#nums))+1]"
      "\t\t\ttrain[w+j]=n"
      "\t\t\tdel(nums,n)"
      "\t\t\t"
      "\t\tend"
      "\t\ttrain[w+3] = 8"
      "\tend"
      "\t"
      "\ttrain[0]=9"
      "\t"
      "\tfor j=0,2 do"
      "\t\ttrain[tl*4+j]=30"
      "\tend"
      "\ttrain[(tl+1)*4 - 1]=31"
      "end"
      ""
      "function clone_room(a,b)"
      "\tlocal ax = (a%8)*16"
      "\tlocal ay = (a\\8)*16"
      "\troom_all= {}"
      "\tfor j = 0,15 do"
      "\t\tfor i = 0,15 do"
      "\t\t\tlocal t=mget(ax+i,ay+j)"
      "\t\t\tmset(b*16+i,j,t)"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function update_door()"
      "\tlocal wl = wl"
      "\t--unlock next wagon"
      "\tif #enemies <= 0 and "
      "\tnot enemiescleared then"
      "\t\t"
      "\t\tsfx(37)"
      "\t\tsfx(42)"
      "\t\t"
      "\t\tlocal x=(wl-1)*16"
      "\t\tlocal g=rnd_gun()"
      "\t\t"
      "\t\tmake_drop(x*8+60,56,g.spr,\"gun\","
      "\t\tcopy(g))"
      "\t\tenemiescleared=true"
      "\t\t"
      "\t\tfor i=1,5 do"
      "\t\t\tmake_ptc("
      "\t\t\t  x*8 + rrnd(8),"
      "\t\t\t  56  + rrnd(8),"
      "\t\t\t8+rnd(8),rnd{9,10})"
      "\t\tend"
      "\t\t"
      "\t\tif wagon_n < tl then"
      "\t\t\tmset(x,6,40)"
      "\t\t\tmset(x,7,39)"
      "\t\telse"
      "\t\t\tinit_boss_room(x)"
      "\t\tend"
      "\t\t"
      "\t\tshake += 5"
      "\t\t"
      "\tend "
      "end"
      ""
      "function init_boss_room(x)"
      "\tmset(x,4,40)"
      "\tfor i=5,9 do"
      "\t\tmset(x,i,39)"
      "\tend"
      "\tmset(x,10,12)"
      "end"
      ""
      "function begin_boss()"
      "\tlocal x = (wl-1)*16"
      "\tspawn_enemy(x*8+8*12,"
      "\t56,enemy.boss)"
      "\t"
      "\tmset(x,i,6)"
      "\tfor i=5,9 do"
      "\t\tmset(x,i,6)"
      "\t\tburst_ptc(x*8,i*8,10)"
      "\tend"
      "\tmset(x,i,6)"
      "end"
      ""
      "function update_room()"
      "\tfor i=0,3 do"
      "\t\tlocal w=wagon_n*wl + i"
      "\t\t"
      "\t\t--printh(\"train[\"..tostr(w)..\"]:\"..tostr(train[w]))"
      "\t\tclone_room(train[w],i)"
      "\tend"
      "\tprinth(\"---\")"
      "end"
      ""
      "function draw_map()"
      "\t-- wall palette"
      "--\tif(pal_n>#trainpal) pal_n=1"
      "--\tpal(8,trainpal[pal_n][1])"
      "--\tpal(14,trainpal[pal_n][2])"
      ""
      " -- zep:"
      " pal_n=min(7,pal_n)"
      " pal(8,trainpal[pal_n*2-1])"
      " pal(14,trainpal[pal_n*2])"
      "\t"
      "\tdraw_ghost_connector()"
      "\tmap()"
      "\tdraw_random()"
      "\t"
      "\tpalt()"
      "\tpal()"
      "end"
      ""
      "function break_crate(x,y)"
      "\t--spawn_loot(x\\8*8,y\\8*8)"
      "\tspawn_loot(x&~7,y&~7) -- zep"
      "\t"
      "end"
      ""
      ""
      ""
      "function swichtile(x,y)"
      " local t = mget((x\\8),(y\\8))"
      " mset((x\\8),(y\\8),t+1)"
      "end"
      ""
      "function parcourmap()"
      ""
      " local x1=0"
      " if(wagon_n==0)x1=16"
      " \tfor x=x1,16*(wl-1) do"
      "  \tfor y=2,12 do"
      "   \tif x>3 or p.y-1000>y*8 or p.y+1000<y*8 then"
      "    \tif mget(x,y)==109 then"
      "   \t  mset(x,y,39)"
      "   \t  if rnd(4)>3 then"
      "   \t  spawn_enemy(x * 8,y * 8,enemy.explosive_barrel)"
      "   \t  end"
      "    \telseif fget(mget(x,y),2) and ceil(rnd(max(3,diffi-(wagon_n*1.65))))==1 then"
      "      sapwnrndenemy(x,y)"
      "    \tend"
      "   \tend"
      "  \tend"
      "  end"
      " end"
      ""
      ""
      "function sapwnrndenemy(x,y)"
      "\t--spawn explosive_barrel "
      "      if ceil(rnd(25))==10 then"
      "      spawn_enemy(x * 8,y * 8,enemy.explosive_barrel)"
      "     --spawn juggernaut"
      "     elseif ceil(rnd(32))>31-(wagon_n*0.7) and wagon_n>1 then"
      "      spawn_enemy(x * 8,y * 8,enemy.juggernaut)"
      "     "
      "     --spawn warm"
      "     elseif ceil(rnd(30))>28.5-(wagon_n*0.5) and wagon_n>0 then"
      "      for i=0,ceil(rnd(wagon_n/2))+8 do"
      "      spawn_enemy(x * 8,y * 8,enemy.warm)"
      "      end"
      "     "
      "     --spawn tourelle "
      ""
      "      elseif ceil(rnd(30))>32.5-(wagon_n*1) and wagon_n>2 then"
      ""
      "      spawn_enemy(x * 8,y * 8,enemy.tourelle)"
      "     --spawn hedgehog "
      "     else "
      "      if ceil(rnd(23))>27-(wagon_n*2.5) then"
      "       spawn_enemy(x * 8,y * 8,enemy.hedgehogbuff)"
      "      else spawn_enemy(x * 8,y * 8,enemy.hedgehog)"
      "      "
      "     end"
      "     end"
      "end"
      "-->8"
      "--enemies"
      "function make_enemy(x,y,spr,"
      "spd,life,agro,chase,seerange,"
      "gunt)"
      "\treturn {"
      "\t\tx=x, y=y,"
      "\t\tangle=0,"
      "\t\t"
      "\t\tpangle=0,"
      "\t\t"
      "\t\tdx=0,dy=0,"
      "\t\tspd=spd,"
      "\t\tagro=agro,"
      "\t\t"
      "\t\tbx=1,by=1,"
      "\t\tbw=6,bh=6,"
      "\t\t"
      "\t\thx=0,hy=0,"
      "\t\thw=8,"
      "\t\t"
      "\t\tchase=chase,"
      "\t\tseerange=seerange,"
      "\t\tspr=spr,"
      "\t\tlife=life,"
      "\t\t"
      "\t\tgun=gunt,"
      "\t\tcd=30,"
      "\t\ttimer = 0,"
      "\t\ta=0,"
      "\t}"
      "end"
      ""
      "function init_enemies()"
      "\tenemy= {"
      "\t"
      "\thedgehog=make_enemy("
      "--x,y,sprite,speed,life,shootrange,  "
      "\t x,y,108   ,1    ,5   ,7.75   ,"
      "--chase,seerange"
      "\t false,1,"
      "\t guns.gunslime),"
      "\t "
      "\thedgehogbuff=make_enemy("
      "--x,y,sprite,speed,life,shootrange,  "
      "\t x,y,92   ,1    ,10   ,7.75   ,"
      "--chase,seerange"
      "\t false,1,"
      "\t guns.gunslimebuff),"
      "\t "
      "\t "
      "  juggernaut=make_enemy("
      "--x,y,sprite,speed,life,shootrange,  "
      "\t x,y,94    ,1.5  ,30  ,3   ,  "
      "--chase,seerange"
      "  true,8, "
      "\t guns.shotgunmechant),"
      "\t "
      "\t warm=make_enemy("
      "--x,y,sprite,speed,life,shootrange,  "
      "\t x,y,126    ,1  ,1  ,0   ,  "
      "--chase,seerange"
      "  true,6.5, "
      "\t guns.null),"
      "\t "
      "\t tourelle=make_enemy("
      "--x,y,sprite,speed,life,shootrange,  "
      "\t x,y,125   ,0    ,15   ,6.5   ,"
      "--chase,seerange"
      "\t false,1,"
      "\t guns.machinegunmechant),"
      "\t "
      "\t explosive_barrel=make_enemy("
      "--x,y,spr,speed,life,shootrange,  "
      "\t x,y,109  ,0    ,0.1 ,0,"
      "--chase,seerange"
      "\t false,0,"
      "\t guns.explosion),"
      "\t "
      "\tboss=make_enemy("
      "--x,y,spr,speed,life,shootrange,  "
      "\t x,y,1  ,3    ,300 ,32,"
      "--chase,seerange"
      "\t true,32,"
      ""
      "\t guns.boss_360gun),"
      "}"
      ""
      "local b=enemy.boss"
      "b.bw = 15"
      "b.bh = 15"
      "b.hw = 16"
      "b.guns = {guns.boss_targetgun,"
      "guns.boss_360gun,"
      "guns.boss_enemygun}"
      "b.phase = 0"
      "b.phasetimer = 0"
      "b.pause=0"
      ""
      "end"
      ""
      "function spawn_enemy(x,y,name)"
      "\tlocal a=copy(name)"
      "\ta.x = x"
      "\ta.y = y"
      "\ta.gun = copy(a.gun)"
      "\tlocal r = rnd(60)"
      "\tif(a.spr==1)r = 0"
      "\tif (a.spr != 125)a.gun.cooldown += r"
      "\t"
      " if (a.spr == 126)a.spd = 0.8+rnd(0.4)"
      " if a.x<175 then"
      "  a.gun.timer += 90"
      "  a.timer = 90"
      " end"
      " "
      "\tadd(enemies,a)"
      "end"
      ""
      "function update_enemy(e)"
      "\tfor i in all(enemies) do"
      "\t\tif loaded(i) then"
      "\t\t\tmouvrnd = true"
      "\t\t\t"
      "\t\t\ti.gun.timer = max(i.gun.timer-1--/#enemies"
      "\t\t\t,0)"
      "\t\t\t"
      "\t\t\tif i.gun.timer<=0 and "
      "\t\t\t(canshoot(i,p) or i.spr==1)then"
      "\t\t\t\t"
      "\t\t\t\ti.gun:fire(i.x+4,i.y+4,i.a)"
      "\t\t\tend"
      "\t\t\tif mouvrnd then"
      "\t\t\t\tchangedirection(i)"
      "\t\t\tend"
      "\t\t\tcollide(i,0.1)"
      "\t\t\t"
      "\t\t\ti.pangle=atan2(p.x-i.x,p.y-i.y)"
      "\t\t\tif not (i.spr== 109) then"
      "\t\t\t\ti.flip=isleft(i.pangle)"
      "\t\t\tend"
      "\t\t\t"
      "\t\t\tif(i.spr==1) update_boss(i)"
      "\t\t\t"
      "\t\t\ti.x += i.dx"
      "\t\t\ti.y += i.dy"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function draw_enemy(e)"
      "\tlocal w = 1"
      "\tif(e.spr==1)w=2"
      "\t"
      "\tlocal x=flr(e.x)+"
      "\tcos(e.pangle)*6*w"
      "\tlocal y=flr(e.y)+"
      "\tsin(e.pangle)*3*w"
      "\t"
      "\tspr(e.gun.spr,x,y,1,1, e.flip)"
      "\t"
      "\tspr(e.spr,e.x,e.y,w,w, e.flip)"
      "\t"
      "\t--boss health bar"
      "\tif e.spr==1 then"
      "\t\trectfill(camx+1,120,"
      "\t\tcamx+126,126,4)"
      "\t\tlocal l=126*(e.life/300)"
      "\t\trectfill(camx+2,121,camx+2+l,"
      "\t\t125,9)"
      "\t\t"
      "\t\tlocal s=\"🐱\"..ceil(e.life)..\"/\"..\"300\""
      "\t\tprint(s, camx+3,121,7)"
      "\tend"
      "\t"
      "\t--print(e.life, e.x,e.y-8,7)"
      "\t--circ(e.x+4,e.y+4,e.r,12)"
      "\t--print(e.gun.timer,e.x,e.y)"
      "\t--print(abs(e.dy)+abs(e.dx),e.x,e.y+6)"
      "end"
      ""
      "function update_boss(i)"
      "\ti.phasetimer -= 1"
      "\ti.pause -= 1"
      "\t"
      "\tif i.phasetimer<0 then"
      "\t\ti.phasetimer=600+rnd(600)"
      "\t\ti.phase+=1"
      "\t\ti.pause = 200"
      "\tend"
      "\tif(i.phase>3)i.phase=1"
      "\t"
      "\ti.gun=i.guns[i.phase]"
      "\tif(i.pause>0) i.gun = guns.null"
      "end"
      ""
      "function changedirection(i)"
      "\ti.timer-=1"
      "\tif i.timer < 1 then"
      "\t i.angle += rrnd(0.25)"
      "\t i.timer=i.cd"
      "\t i.dx=cos(i.angle)/8*i.spd "
      "\t i.dy=sin(i.angle)/8*i.spd"
      "\tend"
      "end"
      ""
      "function canshoot(e,pl)"
      "\tlocal angle = atan2(pl.x-e.x,"
      "\tpl.y-e.y)"
      "\te.a=angle"
      "\tlocal x = cos(angle)"
      "\tlocal y = sin(angle) "
      "\tlocal dist = dist(e,pl)"
      "\t"
      "\tif (abs(dist)<e.agro and abs(pl.x-e.x)<128) or e==p then"
      "\t\treturn cansee(e,angle,x,y,dist)"
      "\telseif abs(dist)<e.seerange and abs(dist)>e.agro and e.chase and cansee(e,angle,x,y,dist) then"
      "  o= e.dx+e.dy"
      "   e.dx=x*(e.spd*2)/max(dist,4)"
      "   e.dy=y*(e.spd*2)/max(dist,4)"
      "   "
      "    mouvrnd = false"
      "   "
      "  "
      " end\t"
      "end"
      ""
      "function dist(e,p)"
      "\treturn sqrt(abs(p.y-e.y)^2+abs(p.x-e.x)^2)/8"
      "end"
      " "
      "function cansee(e,angle,x,y,dist)\t "
      " for i =1,dist do"
      "\tadd(checker,{x=e.x+x*i*8,y=e.y+y*i*8})  "
      "\t if is_solid(checker[#checker].x+4,checker[#checker].y+4) then"
      "\t \tdelchecker()"
      "\t \tif (e!=p) e.gun.timer = e.gun.cooldown/2"
      "\t return false "
      "\t end"
      "\tend"
      "\tdelchecker() "
      "\treturn true "
      "end"
      ""
      ""
      "function delchecker()"
      "\tchecker = {}"
      "end"
      ""
      "function loaded(i)"
      "\treturn abs(camx+64-i.x)<71--71"
      "end"
      "-->8"
      "--particles & bg"
      "function init_ptc()"
      "\tparticles={}"
      "\tgrass = {}"
      "\tfor i=0,20 do "
      "\tadd(grass,{x=flr(rnd(16))*8, y=flr(rnd(16))*8, spr=56})"
      "\tend"
      "\tfor i=0,5 do "
      "\tadd(grass,{x=flr(rnd(16))*8, y=rnd{0,112}, spr=56})"
      "\tend"
      "\tfor i=0,3 do"
      "\tfor v=4,14 do"
      "\tadd(grass,{x=32*i,y=v*8,spr=24})"
      "\tend"
      "\tend"
      "\tweelflip = true"
      "\tweelframe = 5"
      "\tweelcount = weelframe"
      "end"
      ""
      "function make_ptc(x,y,r,col,fric,dx,dy,txt)"
      "\tfric=fric or rnd(.1)+.85"
      "\tdx=dx or 0"
      "\tdy=dy or 0"
      "\tadd(particles, {"
      "\t\tx=x,  y=y,"
      "\t\tdx=dx,dy=dy,"
      "\t\tfric=fric,"
      "\t\t"
      "\t\ttxt=txt,"
      "\t\t"
      "\t\tr=r, col=col,"
      "\t\tdestroy=false,"
      "\t})"
      "end"
      ""
      "function update_ptc(ptc)"
      "\tptc.x += ptc.dx"
      "\tptc.y += ptc.dy"
      "\t"
      "\tptc.dx *= ptc.fric"
      "\tptc.dy *= ptc.fric"
      "\t"
      "\tptc.r *= ptc.fric"
      "\t"
      "\tif(ptc.r<=1)ptc.destroy=true"
      "end"
      ""
      "function draw_ptc(ptc)"
      "\t--kinda bodgey but whatever"
      "\tif ptc.txt==nil then"
      "\t\tcircfill(ptc.x,ptc.y,ptc.r,ptc.col)"
      "\telse"
      "\t\tprint(ptc.txt,ptc.x,ptc.y,ptc.col)"
      "\tend"
      "end"
      ""
      "function burst_ptc(x,y,col)"
      "\tfor i=1,5 do"
      "\t\tmake_ptc("
      "\t\t   x+rrnd(8),"
      "\t\t   y+rrnd(8),"
      "\t\t   rnd(5)+5,col,"
      "\t\t   0.9+rnd(0.07))"
      "\tend "
      "end"
      ""
      "function grasstile()"
      "\tfor i in all(grass)do"
      "\t i.x = i.x"
      "\t\ti.x-=2.5"
      "\t\tif (i.x<-8)i.x = 128"
      "\tend"
      "end"
      ""
      "function drawgrass()"
      "\tfor elt in all(grass)do"
      "\t\tspr(elt.spr,camx+elt.x,elt.y)"
      "\tend"
      "end"
      ""
      "function draw_weel()"
      " weelcount -=1"
      " if (weelcount<1) weelflip = not weelflip weelcount=weelframe"
      " for n=0,5 do"
      "\tfor i=0,2 do"
      "\t\tspr(42,8+n*64+i*16,14*8, 2,2,weelflip)--, flip_x ,flip_y)"
      "\tend"
      "\tend"
      "end"
      ""
      "----"
      ""
      ""
      "-->8"
      "--menus"
      "function init_menus()"
      "\tmenus = {}"
      "\tmenus.main = make_main_menu()"
      "\tmenus.death = make_death_menu(false)"
      "\tmenus.bossdeath = make_boss_death()"
      "\tmenus.win = make_death_menu(true)"
      "end"
      ""
      "--[["
      "function draw_bar(t,x,y,w,w2,c,c2)"
      "\trectfill(x,y,"
      "\tx+w+2,y+5,c2)"
      "\tlocal l=w*w2"
      "\trectfill(x+1,y+1,"
      "\tx+1+l,y+5,c)"
      "\t"
      "\tprint(t, x+1,y+1,7)"
      "end--]]"
      ""
      "function make_boss_death()"
      "\tlocal m={"
      "\ttimer=400,"
      "\t"
      "\tupdate=function(m)"
      "\t\tfor e in all(enemies)do del(e,enemies) end"
      "\t\tmusic(-1,0)"
      "\t\tif(m.timer==400)sfx(45)--sfx(46)"
      "\t\t"
      "\t\tm.timer -= 3"
      "\t\t"
      "\t\tif m.timer<0 then"
      "\t\t\tmenu = \"game\""
      "\t\t\twin=true"
      "\t\t\tshake += 40"
      "\t\t\tsfx(48)"
      "\t\t\t"
      "\t\t\tfor i=1,18 do"
      "\t\t\t\tmake_ptc(camx+rnd(128),"
      "\t\t\t\trnd(128),50+rnd(20),"
      "\t\t\t\trnd{8,9,10},.95)"
      "\t\t\t\t"
      "--(x,y,r,col,fric,dx,dy,txt)"
      "\t\t\tend"
      "\t\tend"
      "\t\t"
      "\t\tmx,my=-10,-10"
      "\tend,"
      "\t"
      "\tdraw=function(m)"
      "\t\t"
      "\t\tlocal x,y = boss_pos[1]+8,boss_pos[2]+8"
      "\t\tlocal flp = boss_pos[3]"
      "\t\tlocal t = m.timer"
      "\t\tcircfill(x,y,t    ,8)"
      "\t\tcircfill(x,y,t*.75,9)"
      "\t\tcircfill(x,y,t*.5 ,10)"
      "\t\tcircfill(x,y,t*.25,7)"
      "\t\tspr(1,x-8,y-8,2,2,flp)"
      "\tend"
      "\t}"
      "\treturn m"
      "end"
      "------"
      ""
      "function make_main_menu()"
      "\t--this code could be better"
      "\tlocal m = {"
      "\t  update=update_main_menu,"
      "\t  draw=draw_main_menu,"
      "\t  "
      "\t  sel=0,"
      "\t  done=false,"
      "\t  ui_oy=0,"
      "\t  ui_dy=0,"
      "\t  "
      "\t  has_active=false,"
      "\t}"
      "\tm.buttons={}"
      "\t"
      "\tlocal names=split\"pigeon,duck,sparrow,parrot,toucan,flamingo,eagle,seagull,ostrich,penguin,jay,chicken\""
      "\tlocal x=4"
      "\tlocal y=105"
      "\tfor i=1,12 do"
      "\t\tadd(m.buttons,{"
      "\t\t  n=i,"
      "\t\t  spr=i+79,"
      "\t\t  bird=i+111,"
      "\t\t  "
      "\t\t  x=i*10-6,"
      "\t\t  y=105,"
      "\t\t  w=9,"
      "\t\t  h=17,"
      "\t\t  col=1,"
      "\t\t  sh=2,"
      "\t\t  "
      "\t\t  name=names[i],"
      "\t\t  active=false,"
      "\t\t})"
      "\tend"
      "\t"
      "\t-------"
      "\tfunction make_btn(args)"
      "\t\tn,sp,bird,x,y,w,h,name=unpack(split(args))"
      "\t\treturn {"
      "\t\t  n=n,"
      "\t\t  spr=sp,"
      "\t\t  bird=bird,"
      "\t\t  "
      "\t\t  x=x,y=y,"
      "\t\t  w=w,h=h,"
      "\t\t  "
      "\t\t  oy=0,"
      "\t\t  col=1,"
      "\t\t  sh=1,"
      "\t\t  "
      "\t\t  name=name,"
      "\t\t  active=false,"
      "\t\t}"
      "\tend"
      "\t-------"
      "\tm.buttons[0]=make_btn(\"0,124,39,114,91,9,9,random\")"
      "\t\t"
      "\tm.buttons[13]=make_btn(\"13,111,39,2,2,9,9,random\")"
      "\t"
      "\treturn m"
      "end"
      ""
      "function update_main_menu(m)"
      "\tlocal selection=1000"
      "\t"
      "\tif not m.done then"
      "\t\t--update buttons"
      "\t\tfor k=0,#m.buttons do"
      "\t\t\tlocal i = m.buttons[k]"
      "\t\t\t"
      "\t\t\t--on hover"
      "\t\t\tif touches_rect(mx,my,i.x,i.y,"
      "\t\t\ti.x+i.w-1, i.y+i.h-1) then"
      "\t\t\t\ti.col = 7"
      "\t\t\t\ti.oy = 2"
      "\t\t\t\t"
      "\t\t\t\tif(not i.active) sfx(43)"
      "\t\t\t\tm.has_active=true"
      "\t\t\t\tm.sel = i.n"
      "\t\t\t\ti.active=true"
      "\t\t\t\t"
      "\t\t\t\t-- on click"
      "\t\t\t\tif lmb then "
      "\t\t\t\t\tselection = i.n"
      "\t\t\t\tend"
      "\t\t\t"
      "\t\t\telse"
      "\t\t\t\t"
      "\t\t\t\ti.active = false"
      "\t\t\t\ti.col = 1"
      "\t\t\t\ti.oy = 0"
      "\t\t\t\t"
      "\t\t\tend--if"
      "\t\tend--for"
      "\t\t"
      "\t\t--buttons"
      "\t\tfor n=0,1 do"
      "\t\tif(btnp()>0)sfx(43)"
      "\t\tif(btnp(⬅️,n))m.sel -= 1"
      "\t\tif(btnp(➡️,n))m.sel += 1"
      "\t\tif(btnp(⬆️,n))m.sel=(m.sel==0)and 13 or 0"
      "\t\tif(btnp(⬇️,n))m.sel=1"
      "\t\tend"
      "\t\tif(btn(❎)or btn(🅾️))selection=m.sel"
      "\t\t"
      "\t\tm.sel%=14"
      "\t\tlocal b=m.buttons[m.sel]"
      "\t\tb.active = true"
      "\t\tm.has_active=true"
      "\t\tb.oy,b.col = 2,7"
      "\t\t"
      "\t\t"
      "\t\t-- run selection"
      "\t\tif selection<=12 then"
      "\t\t\tm.done = true"
      "\t\telseif selection==13 then"
      "\t\t\thardmodetimer+=1"
      "\t\telse"
      "\t\t\thardmodetimer=0"
      "\t\tend"
      "\telse"
      "\t\t--animation "
      "\t\tm.ui_dy += .1"
      "\t\tm.ui_oy += m.ui_dy"
      "\t\t"
      "\t\tif m.ui_dy > 5 then"
      "\t\t\tbirdchoice = m.sel"
      "\t\t menu = \"game\""
      "\t\t\tbegin_game()"
      "\t\t\treturn"
      "\t\tend "
      "\tend"
      "end"
      ""
      "function draw_main_menu(m)"
      "\tlocal oy = m.ui_oy"
      "\t"
      "\tpalt(0,false)"
      "\t"
      "\tdraw_logo(44,5-oy)"
      "\t"
      "\t--player selection"
      "\trectfill(112,89+oy,125,110+oy,12)"
      "\trectfill(2,103+oy,125,124+oy,1)"
      "\tfor k=0,#m.buttons do"
      "\t\ti = m.buttons[k]"
      "\t\t"
      "\t\toy = abs(oy)"
      "\t\tif(k == 13)oy = -oy"
      "\t\t"
      "\t\trectfill(i.x, "
      "\t\ti.y-i.oy + oy, "
      "\t\ti.x+i.w, "
      "\t\ti.y+i.h-i.oy + oy, "
      "\t\ti.col)"
      "\t\tspr(i.spr, "
      "\t\ti.x+1, "
      "\t\ti.y+1-i.oy + oy,"
      "\t\t1,i.sh)"
      "\t\t"
      "\t\tif i.n==13and i.active then"
      "\t\t\toprint(\"a game by:\",2,13, 14)"
      "\t\t\toprint([[yOLWOOCLE"
      "gOUSPOURD"
      "nOTGOYOME"
      "sIMON t.]],2,13)"
      "\t\t\toprint([[code,art"
      "code"
      "code"
      "music]],45,13, 13)"
      "\t\tend"
      "\tend"
      "\toy=abs(oy)"
      "\t"
      "\t-- buttons"
      "\tlocal sel=m.buttons[m.sel]"
      "\trectfill("
      "\t2,93+oy,"
      "\t2+#sel.name*8, 102+oy,1)"
      "\twide(sel.name,4,95+oy,7)"
      "\tpalt()"
      "\t"
      "\t-- encaged bird"
      "\tpalt(1,true)"
      "\tspr(sel.bird,6*8,7*8)"
      "\tspr(32,6*8,7*8)"
      "\tpalt()"
      "end"
      ""
      "function draw_logo(x,y)"
      "\t--\"birds\""
      "\toxxl(\"birds\",x,y,10)"
      "\toxxl(\"guns\",x+4,y+15, 6)"
      "\t"
      "\t--\"with\""
      "\toprint(\"with\",x+11,y+10)"
      "\t"
      "\toprint(\"with\",x+11,y+9)"
      "end"
      ""
      "function oxxl(t,x,y,col)"
      "\t--credit to freds72"
      "\tfor ix=-2,2 do"
      "\t\tfor iy=-2,4 do"
      "\t\t\tif abs(ix)==2 "
      "\t\t\tor abs(iy)>=2 then"
      "\t\t\t\tprint(\"\\^p\"..t,x+ix,y+iy,1)"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "\t"
      "\tcol=col or 7 "
      "\tfor ix=-1,1 do"
      "\t\tfor iy=-1,1 do"
      "\t\t\tprint(\"\\^p\"..t,"
      "\t\t\tx+ix,y+iy,col)"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function wide(t,x,y,col,pre)"
      "\t--credit to yolwoocle uwu"
      "\tt1= \"                ! #$%&'()  ,-./[12345[7[9:;<=>?([[c[efc[ij[l[[([([st[[[&yz[\\\\]'_`[[c[efc[ij[l[[([([st[[[&yz{|}~\""
      "\tt2=\"                !\\\"=$  '()*+,-./0123]5678]:;<=>?@abcdefghijklmnopqrstuvwx]z[\\\\]^_`abcdefghijklmnopqrstuvwx]z{|} \""
      "\tn1,n2=\"\",\"\""
      "\tpre=pre or \"\""
      "\t"
      "\tfor i=1,#t do"
      "\t\tlocal char = sub(t,i,i)"
      "\t\tlocal c=ord(char)-16"
      "\t\tn1..=sub(t1,c,c)..\" \""
      "\t\tn2..=sub(t2,c,c)..\" \""
      "\tend"
      "\t"
      "\tif(col!=nil)color(col)"
      "\tprint(pre..n1,x,y)"
      "\tprint(pre..n2,x+1,y)"
      "end"
      ""
      ""
      "-->8"
      "--drops"
      "function make_drop(x,y,spr,type,q)"
      "\tadd(drops,{"
      "\t x=x, y=y,"
      "\t bx=8,dy=8,"
      "\t "
      "\t spr=spr,"
      "\t type=type,"
      "\t "
      "\t q=q,"
      "\t touched=false,"
      "\t cooldown=0,"
      "\t "
      "\t destroy=false,"
      "\t})"
      "end"
      ""
      "function update_drops()"
      "\tfor d in all(drops) do"
      "\t\td.cooldown=max(0,d.cooldown-1)"
      "\t\t"
      "\t\tlocal touches = touches_rect("
      "\t\tp.x+4,p.y+4,"
      "\t\td.x,d.y,d.x+8,d.y+8)"
      "\t\t"
      "\t\tif(not touches)d.touched=false"
      "\t\tif touches then"
      "\t\t\t"
      "\t\t\tlocal col=7"
      "\t\t\tlocal txt=\"\""
      "\t\t\tlocal do_ptc = false"
      "\t\t\t"
      "\t\t\tif d.type==\"ammo\" then"
      "\t\t\t\td.destroy = true"
      "\t\t\t\tlocal q = flr(d.q*p.gun.maxammo)"
      "\t\t\t\tp.gun.ammo += q"
      "\t\t\t\t"
      "\t\t\t\tdo_ptc=true"
      "\t\t\t\tcol=9"
      "\t\t\t\ttxt=\"+\"..q..\" ammo\""
      "\t\t\t\t"
      "\t\t\t\tsfx(38)"
      "\t\t\t\t"
      "\t\t\telseif d.type==\"health\"then"
      "\t\t\t\td.destroy = true"
      "\t\t\t\tp.life += d.q"
      "\t\t\t\t"
      "\t\t\t\tdo_ptc=true"
      "\t\t\t\tcol=8"
      "\t\t\t\ttxt=\"+\"..d.q..\" health\""
      "\t\t\t\t"
      "\t\t\t\tsfx(38)"
      "\t\t\t\t"
      "\t\t\telseif d.type==\"gun\" "
      "\t\t\tand not d.touched"
      "\t\t\tand d.cooldown<=0 then"
      "\t\t\t\td.touched = true"
      "\t\t\t\td.cooldown = 60"
      "\t\t\t\t"
      "\t\t\t\tdo_ptc=true"
      "\t\t\t\tcol=6"
      "\t\t\t\ttxt=d.q.name"
      "\t\t\t\t"
      "\t\t\t\tp.gunls[p.gunn],d.q=d.q,p.gunls[p.gunn]"
      "\t\t\t\tupdate_gun(p)"
      "\t\t\t\td.spr = d.q.spr"
      "\t\t\t\t"
      "\t\t\t\tsfx(36)"
      "\t\t\tend"
      "\t\t\t"
      "\t\t\tif do_ptc then"
      "\t\t\t\tfor i=1,5 do"
      "\t\t\t\t\tmake_ptc("
      "\t\t\t\t\t\td.x+rrnd(8),"
      "\t\t\t\t\t\td.y+rrnd(8),"
      "\t\t\t\t\t\trnd(5)+5,col,"
      "\t\t\t\t\t\t0.9+rnd(0.07))"
      "\t\t\t\tend "
      "\t\t\tend"
      "\t\t\t"
      "\t\t\tmake_ptc("
      "\t\t\t\td.x+4-(#txt*2),"
      "\t\t\t\td.y+4,"
      "\t\t\t\trnd(5)+5,7,"
      "\t\t\t\t.98,0,-0.3,txt"
      "\t\t\t)"
      "\t\tend"
      "\t\t"
      "\t\tif(d.destroy)del(drops,d)"
      "\tend"
      "end"
      ""
      "function draw_drops()"
      "\tfor d in all(drops)do"
      "\t\tspr(d.spr,d.x,d.y)"
      "\tend"
      "end"
      ""
      "function spawn_loot(x,y)"
      "\tlocal r = rnd(1)"
      "\t"
      "\tif r < .015 then"
      "\t\tlocal g = rnd_gun()"
      "\t\tmake_drop(x,y,g.spr,\"gun\","
      "\t\tcopy(g))"
      "\telseif r < .045 then"
      "\t\tmake_drop(x,y,79,\"ammo\",1/4)"
      "\t\t"
      "\telseif r < .075 and degaplus == 0 then"
      "\t\tmake_drop(x,y,78,\"health\",2)"
      "\t"
      "\telseif r < .017 and degaplus == 1 then"
      "\t\tmake_drop(x,y,78,\"health\",1)"
      "\tend"
      "end"
      "-->8"
      "--death menu"
      "function make_death_menu(iswin)"
      "\tlocal m = {"
      "\t  update=update_death_menu,"
      "\t  draw=draw_death_menu,"
      "\t  "
      "\t  circt=1,"
      "\t  timer=0,"
      "\t  showtext=false,"
      "\t  "
      "\t  iswin=iswin,"
      "\t  nstats=0,"
      "\t}"
      "\t"
      "\tlocal t,t2=\"retry\",\"change bird\""
      "\tif(iswin)t=\"play again\",\"title screen\""
      "\t"
      "\tm.buttons = {}"
      "\tm.buttons[1]={"
      "\t\tn=1,"
      "\t\tt=t,"
      "\t\tx=0,y=0, oy=0,"
      "\t\tactive=false"
      "\t}"
      "\tm.buttons[2]={"
      "\t\tn=2,"
      "\t\tt=t2,"
      "\t\tx=0,y=0, oy=0,"
      "\t\tactive=false"
      "\t}"
      "\t"
      "\treturn m"
      "end"
      ""
      "function update_death_menu(m)"
      "\tm.circt=min(m.circt*1.05,600)"
      "\t"
      "\t--circle timer"
      "\tif m.circt>=600 then"
      "\t\tif(m.timer==0) music(23)"
      "\t\t"
      "\t\tif(m.timer==220) music(24)"
      "\t\tif m.timer%60==59 "
      "\t\t"
      "\t\t--\"ploop\" sfx on every stat"
      "\t\tand m.nstats<3 then"
      "\t\t\tsfx(41) "
      "\t\t\tm.nstats+=1"
      "\t\tend"
      "\t\t"
      "\t\tm.showtext=true"
      "\t\tm.timer += 1"
      "\tend"
      "\t"
      "\t-- buttons"
      "\tlocal o = 0"
      "\tif keyboard and m.timer>1 then"
      "\t\tif(btn(❎))o=1"
      "\t\tif(btn(🅾️))o=2"
      "\tend"
      "\t"
      "\tfor i=1,#m.buttons do"
      "\t\tlocal b = m.buttons[i]"
      "\t\tlocal t=m.timer / 100"
      "\t\t"
      "\t\tlocal ox = #b.t*2"
      "\t\tb.x = camx + 64 - ox "
      "\t\t+ cos(t+i/10)*1.5"
      "\t\tb.y = 1/t + 80 + i*15 "
      "\t\t+ sin(t+i/10)*1.5"
      "\t\t"
      "\t\tif touches_rect(mx,my,"
      "\t\tb.x-4,b.y-4,"
      "\t\tb.x+#b.t*4+3, b.y+9) then"
      "\t\t\t"
      "\t\t\tif(not b.active)sfx(43)"
      "\t\t\tb.active = true"
      "\t\t\tb.oy = 3"
      "\t\t\tif lmb then"
      "\t\t\t\to = b.n"
      "\t\t\tend"
      "\t\t\t"
      "\t\t\tm.sel = i"
      "\t\t\t"
      "\t\telse"
      "\t\t\tb.active = false"
      "\t\t\t"
      "\t\tend"
      "\tend"
      "\t"
      "\tif(o==1)run(tostr(birdchoice))"
      "\tif(o==2)run(\"-\")"
      "end"
      ""
      "function draw_death_menu(m)"
      "\t--circles animation"
      "\tpalt(0,false)"
      "\tpalt(1,true)"
      "\tlocal col,c2,c3,c4=0,1,2,9"
      "\tlocal txtcol = 7"
      "\tif m.iswin then"
      "\t\tcol,c2,c3,c4=15,9,8,2"
      "\t\ttxtcol = 10"
      "\t\tif(t()%2<1)txtcol = 9"
      "\tend"
      "\t"
      "\tlocal x,y = p.x+4,p.y+4"
      "\tlocal c = m.circt"
      "\tcircfill(x,y,c    ,c4)"
      "\tcircfill(x,y,c*.75,c3)"
      "\tcircfill(x,y,c*.5 ,c2)"
      "\t--spr(p.spr,p.x,p.y)"
      "\tcircfill(x,y,c*.25,col)"
      ""
      "\tpalt()"
      "\t"
      "\t--text & buttons"
      "\tlocal t=m.timer/100"
      "\tlocal txt=m.iswin and "
      "\t   \"congrats!\" or \"game over\""
      "\t"
      "\toxxl(txt,"
      "\t     camx+30+cos(t)*3,"
      "\t     1/t +20+sin(t)*3, txtcol)"
      "\t     "
      "\tfor b in all(m.buttons) do"
      "\t\tlocal a = \"\""
      "\t\tif keyboard then"
      "\t\t\ta = \"🅾️\""
      "\t\t\tif(b.n == 1) a = \"❎\""
      "\t\tend"
      "\t\t"
      "\t\tif b.active then"
      "\t\t\toprint(a..b.t,b.x,b.y-b.oy,1,7)"
      "\t\telse"
      "\t\t\toprint(a..b.t,b.x,b.y,14,1)"
      "\t\tend"
      "\tend"
      "\t"
      "\t--stats"
      "\tlocal i=0"
      "\tfor k,v in pairs(stats)do"
      "\t\tif i<m.nstats then"
      "\t\t\ttext_y = i*8+1/t+40+sin(t+.3)*3"
      "\t\t\toprint(k,camx+35,text_y)"
      "\t\t\toprint(v,camx+80,text_y, 13)"
      "\t\tend"
      "\t\ti+=1"
      "\tend"
      "\t"
      "\tfor i=0,6 do"
      "\t\tlocal txt=\"▒\""
      "\t\tif(i<=wagon_n)txt=\"█\""
      "\t\tif not m.iswin then"
      "\t\t\toprint(txt, camx+37+i*8,"
      "\t\t\t1/t+70+sin(t)*3, 7)"
      "\t\tend"
      "\tend"
      "\t"
      "\t--hard mode prompt"
      "\tif m.iswin then"
      "\t\tlocal txt=\"hold the 'i' button\\non the title screen\\nto unlock hard mode\\n\""
      "\t\tif(degaplus!=0)txt=\"bro what !!!\\nthis mode was not \\nsupposed to be possible !\""
      "\t\toprint(txt"
      "\t\t,camx+25,1/t+70+sin(t)*2, 13)"
      "\tend"
      "end"
      "")
    (p8-section gfx
      "00000000000d500000005d00777777770000000011111111777777766666666d44444444444444444444444444444444eeeeeeeeee1111ee11eeee11ee1111ee"
      "000000000005750000057500777777776d000066111111117d6116dd65dddd5524444422444444444444444424411422eeeeeeeeee1111ee1eeeeee1ee1111ee"
      "00700700000577794467750077777777ddd006dd111111117611116d6dddddd522244444222222224444444422211444ee1111eeee1111eeee1111eeee1111ee"
      "000770000700576999976d009999999907776760777777777611116d6dddddd5444442242222222244444444444d1224ee1111eeee1111eeee1111eeee1111ee"
      "0007700077604999999999007777777706666660999999997661166d6dddddd5444444444444444444444444444d4444ee1111eeee1111eeee1111eeee1111ee"
      "007007007770455999995900111111116dd00dd6777777777661166d6dddddd5422244444444444444444444422d4444ee1111eeee1111eeee1111eeee1111ee"
      "00000000679074855955940011111111dd0000dd777777777d6666dd65dddd5544444444222222222222222244464444ee1111eeee1111eeee1111ee8eeeeee8"
      "0000000009906788998840001111111100000000777777776dddddddd555555522222222222222222222222222262222ee1111eeee1111eeee1111ee88eeee88"
      "77777777049907777117600077777776222222224444444112211111555555554424424414444444111bb111444644446666666614444441eeeeeeee888e8ee8"
      "77777777000ddd67777770007000770d222222224444444121124111555555554424424414444444111331b1244644226666666614444441eeeeeeee888e8ee8"
      "7777777700dd66666d8867007007700d4244444444444441114444210000000042244444144444441b13313122264444666666661444444111111111888e8ee8"
      "777777770055ddddd28e86007077000d2444444444444441122444210000000042444442144444441313333144464114666666661446444111111111888e8ee8"
      "7777777705557777d28886507770700d42444467444444412422422100000000424244421444444413333411444d1441666666661443444111111111888e8ee8"
      "7777777756d556666d2867557707000d2444444444444421244222110000000044424442124444441143341142ddd4417777777714b3344111111111188e8ee1"
      "777777775dd5566666677d557070000d2244444422222221124244210000000044444444122222221144441111444414dddddddd14bb3441eeeeeeee118e8e11"
      "7777777705550000000055506dddddd62444444222222211122122210000000044444244112222221122221122111122dddddddd14b33441eeeeeeee11111111"
      "44444441ffffffff111111111111111111111111111111114444444111111111eeeeeeeeeeeeeeee1111122222211111661111111444444111111166111dd111"
      "44444441f444444ffffff1111111111114444444444444114444444111111111eeeeeeeeeeeeeeee11112222222221116661111114444441111116661111d111"
      "44444441f4f4f4fff44ff111111111111444444444444411444444411111111188888888eeeeeeee112221d1d1d222116661111114444441111116661111d111"
      "22222221f4f4f4fff4ffffffffffffff1444444444444411222222211111111188888888ecc777ce1122d1d1d11d22116661111114444441111116661111d111"
      "d16161d1fffffffff4f4ff444444444f1444444444444411d16861d11111111188888888ec777cce022d1d1dd1d11220556111111444444111111655111dd111"
      "6161d1d144444444fff4ff4f4f4f4f4f14444444444444116868d9d11111111188888888e777ddde022011d22d1dd220665666111444444111666566111d1111"
      "61d1d1d142424244ff44ff4f4f4f4f4f122222222222221161d9d1d11111111188888888eeeeeeee022ddd2222d00220666666611444444116666666111d1111"
      "2222222144444444ffffff4f4f4f4f4f1d1d1d1d1d1616112222222111111111888888888888888802200d2222ddd220666666611444444116666666111d1111"
      "666666611111111144444fffffffffff1d1d1d16161717114444444111111111ffffffff00000000622dd6d22d66622666666661144444411666666611111111"
      "66666661ffffffff42224444444444441d161617b71717114444444111411441ffffffff0000000062266d6dd6d6d226556555611444444116555655111dd111"
      "6666666177777777422fffff222222241617c79717b616114444444114444144ff3fffff000000006622d66d6d6d226655566651144444411566655511dddd11"
      "ddddddd177777777444f4f4f2424242417c717a6b6b6bd112222222112424214ff3f3fff0000000066222d6d6d62226655566661144444411666655511dddd11"
      "51d1d151ffffffff111fffff4444444417c6c626b6bd2d11d16a61d122222411ff3f3fff000000006662222222226666555666611222222116666555115dd511"
      "d1d1515144444444111444441111111116c6262d2d2d2d11d9da6a6124424441ffffffff00000000777772222227777755566661122222211666655511155111"
      "d1515151411141441114222411111111162d2d2d2d2d2d11d1d9d16112422421ffffffff00000000dddddddddddddddd55555551111661111555555511111111"
      "ddddddd144444444111444441111111112222222222222112222222111211211ffffffff00000000dddddddddddddddd55555551111661111555555511111111"
      "000000000000000000000000000000000066d6000000000000000000006d6d000008e00000000000000000000000000009aaaa90007777000111110002222200"
      "000000000000000000000000000000000066d60000000000000000000d000060008882800055500000000000000000009a9009a9077777701678761029a9a920"
      "06000000060000000000000000ddd000000dd000d00dd000ddd000dd6000000dee88288e444d5ddd005000800d66aa98a900009a700067771688861029242920"
      "0066660000d666660446d6d6446664000d66666664466666664666ddd44550068888288edd465666d666788800a911a8a000000a000006771678761029a9a920"
      "046ddd00444504404440500044ddd4dd4d44400064466666044050004444500d8888288e554d5ddddddd878809a655a0a000000a000006771766671024949420"
      "4445000044000000440050004040500044050000d005050004408800440000068888288edd505000044000809a59aa90a900009a7000677715ddd51024949420"
      "44000000000000000000000000405000000000000005000000009900060000d0008882805540000004000000a50000009a9009a9077777700111110002222200"
      "0000000000000000000000000000050000000000000000000000880000d6d6000000000004400000000000000000000009aaaa90007777000000000000000000"
      "11111111222222221111111111111111222222221111111155555555444444445555555522222222444444445555552806000005000000000667677000000000"
      "1111111122222222111111111111111122222222112ee21155555555444444445555555522222222cd4444445555288804600054009aa90066668867008ee800"
      "115dd511222222221111111111288821222222221eeeee215567765544446776555eee5522222210cccd4444555288880599999609a77a905c68788608e77e80"
      "17dddd51225335221111111112888882222222102eeeffe157777775444677775efffff2222220007cccd44455d888e7091999910a7777a0666888860e7777e0"
      "557d22d12333339a111111111822888892222100ee1ef0e1d677766d447777dd2fffff2222210000c77ccd4455667777099177190a7777a0556d88d60e7777e0"
      "157d882553333aaa1111111112678866aa92009aee1ee7e1ddd77ddd44777d0622ff22052100000070dc1114566777770077747009a77a900666dd6008e77e80"
      "11d8188d33339aa21111111116772666aaaaa0cce2127f7190077009446776065028e00549994000700c0111510aa77700966690009aa90005d005d0008ee800"
      "11d8188d3003a44211242111177066119aaa0c1cee11fff17909a097444977665f8888fe21109990777cc044d0a22a7000440440000000000d500d5000000000"
      "15dd88dd30139444994442111760566699aa0c1cee2100f1777997774499aa77f828828f2222a0001777764467a211a0004222000000049077700000cccccccc"
      "53ddddd553333994a941422116000666e9909acc2ee000116799a977499a7777f2e22e2f2222a9101177764467911997042777200000400a00000000ccc77ccc"
      "33d3ddd1253333391a742222161006688e00aaa71ee001110719a16749a47777fffeeffe22227aa9c1777444678999774271f1700028720077700000cccccccc"
      "3233d3512233333216777222111288882807777712ee21110600a017444477775feeeff52222777acc1764447788887724f1f1f00288872077700000cc777ccc"
      "2223333122533372116777611128888225777777e11ee21101009006444d77775feeee2522267777cd71444477e88877427fff440818881077700000ccc77ccc"
      "2222232226557744411e1e111928882827777777ee12ee1100000010d6666777552eee2522267777d776444477788e77247777700881818000000000ccc77ccc"
      "62626226d66d554424e11e11aa8889a805777777ee21ee211000001066666677555eeee2222777777774444477777777024777000288882000000000cc7777cc"
      "6666626666666dd51224e421cca88caa00057777eee12ee110010000666666665552eeee222777777764444477777777002202200028820000000000cccccccc"
      "11115d1111113b111111111111288e1110001111111eeee111167711111167111111eef111000011dccccd111111888111d66dd5003bbb000000000001100110"
      "1115ddd1111333b111111111127078710779aa01111e7075116079a1111677711111f0ee1000000111c777c1117888811d6777dd03bbbbb00000000017711771"
      "11152dd111130aa111111111127770770c799990e111ee151167799a1116079951111ff100a70999111d707d167779aa6777776d331bb3100050506017100171"
      "5113dd7711133a991111441118870066077888892eeeee11100005191166777115544ff10000aa111111d771677077887772777d33b1b130000eef0001000010"
      "56623331dddd334111414691aa88881100770118122ee1111000005166666671545544e100077611cd7ccc71677777787728e776333bbbb0000fff0001000010"
      "d566222116664441111461111baa821100000111117171110007000156666771feff4411000776111cd7c761667777616778777622444f400050506017100171"
      "1d666611116444111111111111cc2111100011111171711117700011157776111e11e11100776611117776111667761117777611022222000000000017711771"
      "118181111191911111111111115151111c1c11111121211111911911111e1e111e11e111007550011115151111919111117611110244f4000000000001100110"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "8282928282829282828292828282928282829282828292828282928282829282c0829282c0829282c0829282c082c08282c082929292929292929282c0829282"
      "82c09282c09282c09282c09282c092828282c09292c0c0c09292c08282c0928282829282828292828282928282829282c082928282829282828292828282c082"
      "02137272721302727212a172727272a172122290909090909090905272121212d0c1a0a0d0a0a0c1d0a0a0c1d0c3d02232d060c1c1c1c1c1c1c1c160d0121272"
      "13d0c3c1d0c3c1d0c3c1d0c3c1d0121272e2d01212d0d0d01212d04040d0126363425262727272721272727272727272d0a0a0c1a0a0a0a0a0a0a0c1a0a0d072"
      "1272727272727272727272727272727272132390909090909090905372020202d0727213d0727272d0727213d061d02333d0f28183838383838381f2d0127272"
      "13d07272d07272d07272d07372d0127272e3d072728282827272d0828282127262435363425262631312727272121372d0d37272d37272d37272d37272d3d072"
      "727272d2d2727272e0727272d2d2727272727290909090909090907272720202d072f3d3d072f3d3d0d3f372d072d07272d0f28183838383838381f2d0127272"
      "72d04182824182824182824182d012727272d07272a112a17272d072727272727272425243537272d613425213127272d022327272727272727272727213d072"
      "7272d3d1d2d37272d07272d3d2d1d37272727272727272d672d6727272727202d0727272d0824182d0727272d073d07272d0f28183838383838381f2d0127272"
      "72d07272727272727272d672d6d0727272e2d072727272727272d07272c0c27272724353727272727272435312727272d023337272727272727272d60212d072"
      "727272d2d1727272d0727272d2d27272727272727272727272727272727272728282418282a172a1828241828241827272d090909090909090909090d0727272"
      "72d07272727272727272727272d0727272e3d082929292928241d07272d0c3727272121372727272727263727272727282828282828272727282828282828272"
      "7272d3d2d2d37272f07272d3d1d2d372727272c1a0a0a0a0a0a0c172727272727272727272727272727272727272727272d0a1a1727272727272f3d1d0727272"
      "72d0a17272727272727272d6a1d072727272d07272727272d672d07272d07272727213727272727272726272727272727272727272a1727272a1727272727272"
      "7272729151727272f1727272915172727272d3d17272727272a1d272727272727272727272727272d67272727272727272d0a1a1a1727272727272d3d0727272"
      "7282828282828241418282828282727272728272727272727272827272d0c2121342527272425272726362627272727272727272727272727272727272727272"
      "727272727272727272727272d6727272727272d2727272727272d1d37272727272727272c0824182c0824182c041c07272828282828282824141828282727272"
      "72a112121272727272727272127272727272727272c092c07272727272d0c3137243534252435312124252121213727272727272727272727272727272727272"
      "7272727272727272727272727272727272727291a0a0a0a0c1a051727272727272727202d0727291d0727272d012d002727272a1121222327272223272727272"
      "727272727272727272727272727272727272c07272d040d07272c08282d0727272726343537272721343537272121372c082828282c0727272c082828282c072"
      "721372727272c272d172e272d672727272727272d37272d372d372727272727272720312d04272f3d0f3a0f3d012d01272727272727223337272233372727272"
      "7272727272727212727272727272727272e2d07272d040d07272d0a2b2d0c27272727212137272727262637272727272d022320213827272728213034252d072"
      "121213021272c372d372e372727272a11272727272727272727272727272727272721362d0437212d072f312d013d01272727272727272727272727272727272"
      "727272727272121213a172727272727272e3d07272d040d07272d0a3b3d0c37272727212727272727272137272727272d023331372417272724172134353d072"
      "82829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282"
      "82829282828292828282928282829282828282828282928282828282828292828282928282829282828292828282928282829282828292828282928282829282"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
      "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "8282928282c09282828292828282928282829282828292828282928282829282c08292828282928282829282c082928282829282828292828282928282829282"
      "8282829282828292828282928282829282c0829282c08282828282828282c08282828282828282828282828282828282c082828282829292829292c093939393"
      "a1727272a1d0a1727272d2727213131372e2c272d1c272c1c172e2d172e2c272d0c2727272727272727272e2d0420372c1c1a2b2c1c1c1a2b2c1c1c1a2b2c1c1"
      "7213d0808080b080808080b0808080d072d0425262d01212727272122232d07272021372727213137272121312721213d012727272727272727272829292c093"
      "c2d272d1e2d07272727291a0a0a0c1c172e3c372d3c372727272e3d372e3c372d0c3727272425272727272e3d04372727270a3b370a170a3b370a170a3b37072"
      "c002f0808080b180808080b1808080f072d0435363d012d672d672132333d07272c2d272c2d272c2d272c2d272c2d213d012727272727272727272f2727282c1"
      "c3d372d3e3d07272727272727272727272727272727272727272727272727272d0a1727272435363127272a1d002727272707070707270707070727070707072"
      "d072f18080808080b0b08080808080f172d0727272d07272c07272722232d07272c3d372c3d372c3d372c3d372c3d372d072727272727272727272f27272f331"
      "7272727272d0137213e0c2d172d2e2727272727272a172727272a17272727272828241828282c082828241828272727272f27272f272f27272f272f27272f272"
      "d072a19080808080b1b18080808090a172d0727272d07272d0d672721233d07272727272727272727272727272d672726072727272721272727272f272727231"
      "72c2d1e272d02232a1d0c3d372d3e37272637272d3d2f37272f3d1d372726272727272722232d002020372727272727272f27272f213f27272f202f27272f272"
      "827272729090909090909090909072727282828241d07272d07272721212d072505050505050505050505050505050506072727272721272727272f27272f331"
      "72c3d3e372d0233313d0a172727272727262727272d1f3d672f3d27272726272727272722333d012037272727272727272f27272f213f27272f213f27272f272"
      "727272727272d672d672d672727272727272727272824141828282c082828272010101010101010101010101010101016072727272721272727272f272727231"
      "7272727272f07212d6d0c272d172727272637272d3d2d6f3f3d6d2d372726372c08241828282d08282824182c072727272f27272f212f27272f202f27272f272"
      "c07272c272d172e27272c272d172e2727272727272727272727212d022327272303030303030303030303030303030306072727272721272727272f27272f331"
      "7272727272f1727272d0c372d3727272727272727291a0a0a0a0517272727272d07272720262f0a172727272d072727272f27272f272f27272f272f27272f272"
      "d07272c372d372e37272c372d372e3727272727272727272727272f02333727272727272727272727272727272d672726072727272721272727272f272727231"
      "727272727272727272d0a1727272727272727272727272727272727272727272d00372727272f17272727212d0a1727272c17272c1c1c17272c1c1c17272c172"
      "d07272727272727272727272727272727272727272c0a172727272f17272727272c2d272c2d272c2d272c2d272c2d272d072727272727272727272f27272f331"
      "223272727272727272d0c2d272d1e27272e2c272d1c272727272e2d172e2c272d04202727272727272d60363d0223272e270f3f3e270c2f3f3e270c2f3f370c2"
      "827272727272727272727272727272727272722232d07272727272127272727272c3d372c3d372c3d372c3d372c3d313d012727272727272727272f27272c093"
      "23331312a1727272a1d0c3d372d3e37272e3c372d3c372c1c172e3d372e3c372d043620372727272d6031362d0233372e37013f3e370c3f3f3e370c3f31270c3"
      "72727272c272d172e2c272d172e272727272721233d07272727272727272727272721272727212131372727272727213d012727272727272727272c082828293"
      "82829282828292828282928282829282828292828282928282829282828282828282928282829282828292828282928282829282828292828282928282829282"
      "82828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828282828292928292928293939393"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "93939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393"
      "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"
      "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1")
    (p8-section label
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffff777777777777777777777777777777777777777777777777777777777777777777ff777777777777777777ffffffffffffffffffff"
      "ffffffffffffffffffffff777777777777777777777777777777777777777777777777777777777777777777ff777777777777777777ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77ff77hhhhhhhhhhhhhh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77ff77hhhhhhhhhhhhhh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaahh777777hhaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaahh777777hhaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaahhhhhhhhhhaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaahhhhhhhhhhaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaahhaaaaaahhhhhhaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaahhaaaaaahhaaaaaahhhhhhhhhh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaahhaaaaaahhhhhhaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaahhaaaaaahhaaaaaahhhhhhhhhh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhhhhhaaaaaahhhhhhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77ffffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahhhhhhaaaaaahhhhhhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77efffffffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaahhhhhhhhhhaaaaaahhhhhhaaaaaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77eeeeefffffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaahhhhhhhhhhaaaaaahhhhhhaaaaaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77eeeeeeefffffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahh77hhaaaaaahh77hhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77eeeeeeeeefffffffffff"
      "ffffffffffffffffffffff77hhaaaaaaaaaaaaaahh77hhaaaaaahh77hhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahh77eeeeeeeeeeefffffffff"
      "ffffffffffffffffffffff77hhaaaaaahhaaaaaahhhhhhaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaahhaaaaaahhhhhhhhhhaaaaaahh77eeeeeeeeeeeeffffffff"
      "fffffffffffffffffffffe77hhaaaaaahhaaaaaahhhhhhaaaaaahhhhhhaaaaaahhaaaaaahhaaaaaahhaaaaaahhhhhhhhhhaaaaaahh77eeeeeeeeeeeeefffffff"
      "ffffffffffffffffffffee77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahh77eeeeeeeeeeeeeeffffff"
      "fffffffffffffffffffeee77hhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahhaaaaaahhaaaaaahhaaaaaaaaaaaaaahhaaaaaaaaaaaaaahh77eeeeeeeeeeeeeeefffff"
      "ffffffffffffffffffeeee77hhaaaaaaaaaaaaaahhaaaaaahhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhaaaaaahhaaaaaaaaaahhhhhh77eeeeeeeeeeeeeeeeffff"
      "fffffffffffffffffeeeee77hhaaaaaaaaaaaaaahhaaaaaahhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhaaaaaahhaaaaaaaaaahhhhhh77eeeeeeeeeeeeeeeeefff"
      "fffffffffffffffffeeeee77hhaaaaaaaaaaaaaahhaaaaaahh77hh77hh777777hh777777hh77hh77hhaaaaaahhaaaaaaaaaahhhhhh77eeeeeeeeeeeeeeeeeeff"
      "ffffffffffffffffeeeeee77hhaaaaaaaaaaaaaahhaaaaaahh77hh77hh777777hh777777hh77hh77hhaaaaaahhaaaaaaaaaahhhhhh77eeeeeeeeeeeeeeeeeeff"
      "ffffffffffffffffeeeeee77hhhhhhhhhhhhhhhhhhhhhhhhhh77hh77hhhh77hhhhhh77hhhh77hh77hhhhhhhhhhhhhhhhhhhhhhhhhh77eeeeeeeeeeeeeeeeeeef"
      "ffffffffffffffffeeeeee77hhhhhhhhhhhhhhhhhhhhhhhhhh77hh77hhhh77hhhhhh77hhhh77hh77hhhhhhhhhhhhhhhhhhhhhhhhhh77eeeeeeeeeeeeeeeeeeef"
      "fffffffffffffffeeeeeee77hhhhhhhhhhhhhhhhhhhhhhhhhh77hh77hhhh77hhhhhh77hhhh777777hhhhhhhhhhhhhhhhhhhhhh777777eeeeeeeeeeeeeeeeeeee"
      "fffffffffffffffeeeeee477hhhhhhhhhhhhhhhhhhhhhhhhhh77hh77hhhh77hhhhhh77hhhh777777hhhhhhhhhhhhhhhhhhhhhh777777eeeeeeeeeeeeeeeeeeee"
      "fffffffffffffffeeeeee477hhhhhhhhhhhhhhhhhhhhhhhhhh777777hhhh77hhhhhh77hhhh77hh77hhhhhhhhhhhhhhhhhhhhhh77eeeeeeeeeeeeeeeeeeeeeeee"
      "fffffffffffffffeeeee4477hhhhhhhhhhhhhhhhhhhhhhhhhh777777hhhh77hhhhhh77hhhh77hh77hhhhhhhhhhhhhhhhhhhhhh77eeeeeeeeeeeeeeeeeeeeeeee"
      "fffffffffffffffeeeee4477777777777777hhhhhhhhhhhhhh777777hh777777hhhh77hhhh77hh77hh77hhhhhhhhhhhhhh777777eeeeeeeeeeeeeeeeeeeeeeee"
      "fffffffffffffffeeee44477777777777777hhhhhhhhhhhhhh777777hh777777hhhh77hhhh77hh77hh77hhhhhhhhhhhhhh777777eeeeeeeeeeeeeeeeeeeeeee4"
      "fffffffffffffffeeee44444444444777777hh6666666666hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77hh6666666666hh77eeeeeeeeeeeeeeeeeeeeeeeeee44"
      "ffffeeeeeeeffffeeee44444444444777777hh6666666666hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77hh6666666666hh77eeeeeeeeeeeeeeeeeeeeeeeee444"
      "feeeeeeeeeeeeeffeee4444444444477hhhhhh6666666666hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh6666666666hh77eeeeeee2222eeeeeeeeeeeeee444"
      "eeeeeeeeeeeeeeeeeee4444444444477hhhhhh6666666666hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh6666666666hh77eeeeee222222eeeeeeeeeeee4444"
      "eeeeeeeeeeeeeeeeeee4444444444477hh66666666666666hh666666hh666666hh66666666666666hh66666666666666hh77eeeee22222222eeeeeeeeeee4444"
      "eeeeeeeeeeeeeeeeeeee444444444477hh66666666666666hh666666hh666666hh66666666666666hh66666666666666hh77eeee2222222222eeeeeeeeee4444"
      "eeeeeeeeeeeeeeeeeeee444444444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh666666hhhhhhhhhh77eeee2222222222eeeeeeeeee4444"
      "eeeeeeeeeeeeeeeeeeeee44444444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh666666hhhhhhhhhh77eeee2222222222eeeeeeeeeee444"
      "eeeeeeeeeeeeeeeeeeeee44444444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh66666666666666hh77eeee2222222222eeeeeeeeeee444"
      "eeeeeeeeeeeeeeeeeeeeee4444444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh66666666666666hh77eeeee22222222eeeeeeeeeeeee44"
      "eeeeeeeeeeeeehhhheeeeee444444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh66666666666666hh77eeeeee222222eeeeeeeeeeeeeee4"
      "eeeeeeeeeeehhhhhhhheeeeee4444477hh666666hhhhhhhhhh666666hh666666hh666666hh666666hh66666666666666hh77444eeee2222eeeeeeeeeeeeeeeee"
      "eeeeeeeeeehhhhhhhhhheeeeeee44477hh666666hh666666hh666666hh666666hh666666hh666666hh66666666666666hh77444444eeeeeeeeeeeeeeeeeeeeee"
      "eeeeeeeeehhhhhhhhhhhheeeeeeeee77hh666666hh666666hh666666hh666666hh666666hh666666hh66666666666666hh774444444eeeeeeeeeeeeeeeeeeeee"
      "2222eeeeehhhhhhhhhhhheeeeeeeee77hh666666hh666666hh666666hh666666hh666666hh666666hhhhhhhhhh666666hh77444444444eeeeeeeeeeeeeeeeeee"
      "22222222hhhhhhhhhhhhhheeeeeeee77hh666666hh666666hh666666hh666666hh666666hh666666hhhhhhhhhh666666hh774444444444eeeeeeeeeeeeeeeeee"
      "22222222hhhhhhhhhhhhhheeeeeeee77hh66666666666666hh66666666666666hh666666hh666666hh66666666666666hh7744444444444eeeeeeeeeeeeeeeee"
      "22222222hhhhhhhhhhhhhheeeeeeee77hh66666666666666hh66666666666666hh666666hh666666hh66666666666666hh7744444444444eeehhhheeeeeeeeee"
      "22222222hhhhhhhhhhhhhheeeeeeee77hh66666666666666hhhhhh6666666666hh666666hh666666hh6666666666hhhhhh77244444444444hhhhhhhheeeeeeee"
      "222222222hhhhhhhhhhhheeeeeeeee77hh66666666666666hhhhhh6666666666hh666666hh666666hh6666666666hhhhhh7722244444444hhhhhhhhhheeeeeee"
      "222222222hhhhhhhhhhhheeeeeeeee77hh66666666666666hhhhhh6666666666hh666666hh666666hh6666666666hhhhhh772222444444hhhhhhhhhhhheeeeee"
      "2222222222hhhhhhhhhheeeeeeeeee77hh66666666666666hhhhhh6666666666hh666666hh666666hh6666666666hhhhhh772222444444hhhhhhhhhhhh4eeeee"
      "22222222222hhhhhhhh44eeeeeeeee77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77222224444hhhhhhhhhhhhhh44eee"
      "2222222222222hhhh22244eeeeeeee77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77222224444hhhhhhhhhhhhhh4444e"
      "2222222222222222222244eeeeeeee77hhhhhhhhhhhhhhhhhh77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh777777222222444hhhhhhhhhhhhhh44444"
      "22222222222222222222244eeeeeee77hhhhhhhhhhhhhhhhhh77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh777777222222444hhhhhhhhhhhhhh44444"
      "22222222222222222222224eeeeeee77hhhhhhhhhhhhhhhhhh77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh7722222222224444hhhhhhhhhhhh444444"
      "222222222222222222222224eeeeee77hhhhhhhhhhhhhhhhhh77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh7722222222224444hhhhhhhhhhhh444444"
      "222222222222222222222224eee444777777777777777777777777777777777777777777777777777777777777777777222222222444444hhhhhhhhhh4444444"
      "222222222222222222222222e444447777777777777777777777777777777777777777777777777777777777777777772222222224444444hhhhhhhh44444444"
      "222222222222222222222222444444222222222222224444444444422222222222222222222444444444444444222222222222224444444444hhhh4444444444"
      "22222222222222222222222224442222222222222222224444442222222222222222222222244444444444444422222222222222444444444444444444444444"
      "222222hhhhhhhhh22222222224422222222222222222222444422222222222222222222222444444444444444442222222222224444444444444444444444444"
      "22hhhhhhhhhhhhhhhhh2222222222222222222222222222244222222222222hhhhhhhhh222444444444444444444422222222444444444444444444444444444"
      "hhhhhhhhhhhhhhhhhhhhh22222222222222222222222222222222222222hhhhhhhhhhhhhhh444444444444444444444222244444444444444444444444222222"
      "hhhhhhhhhhhhhhhhhhhhhhh2222222222222222222222222222222222hhhhhhhhhhhhhhhhhhh4444444444444444444444444444444444444444444222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhh222222222222222222222222222222hhhhhhhhhhhhhhhhhhhhhhh44444444444444444444444444444444444444422222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhh2222222222222222222222222222hhhhhhhhhhhhhhhhhhhhhhhhh4444444444444444444444444444444444444222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhh22222222222222222222222222hhhhhhhhhhhhhhhhhhhhhhhhhhh444444444444444444444444444444444422222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhh22222222hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh44444444444444444444222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhh2222222h22222222222222hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2244444444h44444444444444444442222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhh222222h2hhhhhhhh222222222hhhhhhhhhhhhhhhhhhh22222222hhhhhhhhh4h44444444hhhhhh444422222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh22222h2hhhhhhhh222222222hhhhhhhhhhhhhhhhhhh22222222hhh2ee2hh4h444444hhhhhhhhhh4422222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2222h2hh5dd5hh222222222hhhhhhhhhhhh28882hh22222222hheeeee2h4h4444hhhhhhhhhhhhhh22222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2222h2h7dddd5h222533522hhhhhhhhhhh2888882h222222h0h2eeeffeh4h444hhhhhhhhhhhhhhhh2222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh222h2557d22dh22333339ahhhhhhhhhhh8228888h92222h00heehef0eh4h44hhhhhhhhhhhhhhhhhh222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh222h2h57d8825253333aaahhhhhhhhhhh2678866haa92009aheehee7eh4h44hhhhhhhhhhhhhhhhhh222222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh22h2hhd8h88d233339aa2hhhhhhhhhhh6772666haaaaa0cche2h27f7h4h4hhhhhhhhhhhhhhhhhhhh22222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh22h2hhd8h88d23003a442hhh242hhhhh77066hhh9aaa0chcheehhfffh4h4hhhhhhhhhhhhhhhhhhhh22222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2h2h5dd88ddh30h39444h994442hhhh7605666h99aa0chchee2h00fh4hhhhhhhhhhhhhhhhhhhhhhh2222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2h253ddddd5h53333994ha94h422hhh6000666he9909acch2ee000hh4hhhhhhhhhhhhhhhhhhhhhhh2222222222222"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2hh33d3dddhh25333339hha742222hh6h00668h8e00aaa7hhee00hhh2hhhhhhhhhhhhhhhhhhhhhhh222222hhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh3233d35hh22333332hh6777222hhhh28888h28077777hh2ee2hhh2hhhhhhhhhhhhhhhhhhhhhhh222hhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh2223333hh22533372hhh67776hhhh288882h25777777hehhee2hhhhhhhhhhhhhhhhhhhhhhhhhh2hhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh22222322h26557744h4hhehehhhh9288828h27777777heeh2eehhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh62626226hd66d5544h24ehhehhhaa8889a8h05777777hee2hee2hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh66666266h66666dd5hh224e42hhcca88caah00057777heeeh2eehhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh55555555h44444444h55555555h22222222h44444444h55555528hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh55555555h44444444h55555555h22222222hcd444444h55552888hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh55677655h44446776h555eee55h222222h0hcccd4444h55528888hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh57777775h44467777h5efffff2h22222000h7cccd444h55d888e7hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhd677766dh447777ddh2fffff22h222h0000hc77ccd44h55667777hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhddd77dddh44777d06h22ff2205h2h000000h70dchhh4h56677777hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh90077009h44677606h5028e005h49994000h700c0hhhh5h0aa777hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh7909a097h44497766h5f8888feh2hh09990h777cc044hd0a22a70hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh77799777h4499aa77hf828828fh2222a000hh7777644h67a2hha0hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh6799a977h499a7777hf2e22e2fh2222a9h0hhh777644h679hh997hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh07h9ah67h49a47777hfffeeffeh22227aa9hch777444h67899977hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh0600a0h7h44447777h5feeeff5h2222777ahcch76444h77888877hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh0h009006h444d7777h5feeee25h22267777hcd7h4444h77e88877hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh000000h0hd6666777h552eee25h22267777hd7764444h77788e77hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh00000h0h66666677h555eeee2h22277777h77744444h77777777hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh00h0000h66666666h5552eeeeh22277777h77644444h77777777hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
      "")
    (p8-section gff
      "0000040400040100040403040101010108000001030300110403030411030101030b0b0b010101040101010101030104030b0b0b01010100041101010103010400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section map
      "393939393939393939393939393939391c1c1c040404040404040404040404040404040404040404040404041c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c393939000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0c282828282829292829290c3939393904000000000000000000000000000004040000000000000000000000000000040c39393939393939393939393939390c282829282828292828282928282829280c2829280c28282828282828280c2828282828282828282828282828282828280c2829292929290c3939393939393939"
      "0d212727272727272727272829290c3904000000000000000000000000000004040000000000000000000000000000040d07070739393939393939390707070d310d0808080b080808080b0808080d2f0d2425260d21212727272122230d272f203127272727272727213121272731300d2727272727272829290c3939393939"
      "0d212727272727272727272f2727281304000000000000000000000000000004040000000000000000000000000000040d07070707393939393939070707070d200f0808081b080808081b0808080f2f0d3435360d21272727273132330d272f2c2d2e272c1d2e272c2d2e272c1d2e210d27272727272727272728290c393939"
      "0d272727272727272727272f27273f1304000000000000000000000000000004040000000000000000000000000000040d07070707393939393939070707070d271f08080808080b0b08080808081f2f0d2727270d27270c27272722230d272f3c3d3e273c3d3e273c3d3e273c3d3e2f0d272727272727272727272728133939"
      "06272727272727272727272f2727271304000000000000002100000000000004040000000021212100000000000000040d07070707393939393939070707070d271a09080808081b1b08080808091a2f0d2727270d27270d27272721330d272f2727272727272727272727272727271a0d272727272727272727272727131c1c"
      "06272727272727272727272f27273f130400000000000021210000000000000404000000210000002100000000000004280707070739393939393907070707282727270909090909090909090927272f282828140d27270d27272721210d272f0505050505050505050505050505050506272727272727272727272727133939"
      "06272727272727272727272f272727130400000000002100210000000000000404000000000000210000000000000004270707070808080808080808070707272727272727272727272727272727272f272727272814142828280c282828272f0202020202020202020202020202020206272727272727272727272727133939"
      "06272727272727272727272f27273f1304000000000000002100000000000004040000000000210000000000000000040c07070707393939393939070707070c27272c271d272e27272c271d272e272f272727272727272727210d222327272f0303030303030303030303030303030306272727272727272727272727133939"
      "06272727272727272727272f2727271304000000000021212121210000000004040000002121212121000000000000040d07070707393939393939070707070d27273c273d273e27273c273d273e272f272727272727272727270f323327272f2727272727272727272727272727271a0c272727272727272727272727133939"
      "0d272727272727272727272f27273f1304000000000000000000000000000004040000000000000000000000000000040d07070707393939393939070707070d2727272727272727272727272727272f272727270c1a272727271f272727272f2c1d2e272c1d2e272c2d2e272c1d2e2f0d27272727272727272727270c133939"
      "0d212727272727272727272f27270c1304000000000000000000000000000004040000000000000000000000000000040d07070707393939393939070707070d2727272727272727272727272727272f272722230d272727272721272727272f3c3d3e273c3d3e273c3d3e273c3d3e200d2727272727272727270c2928393939"
      "0d212727272727272727270c2828283904000000000000000000000000000004040000000000000000000000000000040d07070717393939393939170707070d2727272c271d272e2c271d272e27272f272721330d272727272727272727272f272727272721313127272727272731300d2727272727270c2929283939393939"
      "2828282828282929282929283939393904000000000000000000000000000004040000000000000000000000000000042817171739393939393939391717172828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282929292929283939393939393939"
      "3939393939393939393939393939393904000000000000000000000000000004040000000000000000000000000000043939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939"
      "1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c04040404040404040404040404040404040404040404040404040404040404043939393939393939393939393939391c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c"
      "1339393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0c39393939393939393939393939390c0c282928282829282828292828282928282829280c282928280c292828282928282829282828292828282928282829280c282928282829280c28292828282928280c292828282928282829282828290c28280c2828282928282829282828292828282928282829282828292828282928"
      "0d07070739393939393939390707070d0d212223272121213131313131212727272731210d080b08080d2121272727271a271a27271a2d271c21211a27271a270d212121212131210d2c2d2e272c2d2e270d0b08272727273d1d272727272e0d21270d2121312727272727313127272727272721212727212127272121272727"
      "0d07070707393939393939070707070d0d213233212131273121212721312721272727270f081b08080f272727272727272727273d271d2727272727272727270d2131316d2121210d3c3d3e273c3d3e270d1b0808272727272d272727273e0d31270d2127271a1a272727272727272727272e0c28282928282928280c2c2727"
      "0d07070707040404040404070707070d0d2131303127272727273127273121272727271a1f090909091f1a2727272727272727272727190a0a0a0a0a1c27272728282828142828280d27272727272727270d0808272727273d1d27272727210d31270d2727271a1a271a27272727272727273e0d3127276d276d3131283c2727"
      "0d070707071c1c1c1c1c1c070707070d0d263621272727272727272727273127272727272727272727272727272727272727272727272727272727272727272727272727272727270d27272727272727272828280c27270c28280c281414282827270d271a271a1a6d1a27270e2727272727270d272727272727272727272727"
      "0d0707070739393939393907070707280d262027272727272727272727312121272c2d2e272727276d272c1d2e27272727272c2d2e27273d2727273d2727272727272727272727270d27272727272d27272727270d27270d27270d1a2727272727270d271a271a1a1a1a27270d27272727273d0d27272727276d27270c272727"
      "060707070704042727040407070707270d242527272716272727272727272127273c3d3e2727272727273c3d3e27272727273c3d3e2727276d276d2727272727272c2d2e272c2d2e0f2c2d2e27272d27272727272814142827270d272727272727270d271a1a1a1a1d6d27270d27272727272728272c272a2b272e270d3d2727"
      "0c07070707393917173939070707070c0d3435272727272727272727272731272727272727276d27272727272727272727272727272727272727272c2d2e2727273c3d3e273c3d3e1f3c3d3e27272d27270e27271a27271a27270d302624252727270d27271d1a1a2d2727270d27272727272727273c273a3b273e270d272727"
      "0d07070707393939393939070707070d0d3026312727272727272727312721312727272727272727272727272727272727272727272727272727273c3d3e2727272727272727272727272727276d3d27270d27272727272727270d263634352727270f2727190a0a152727270d27272727272e0c27272727272727270d2c2727"
      "0d07070707040404040404070707070d0d2030212727272727272727272121272727272c2d2e27272c2d2e2727272727273d27273d27273d272727272727272727272727272727272727272727272727270d2727276d276d27270d1a2727272727271f27273d3d3d3d2727210d21272727273e0d27272727272727270d3c2727"
      "0d07070707393939393939070707070d0d3620202024252627222321213127272727273c3d3e27273c3d3e2727272727210a0a0a0a0a0a0a0a0a272727272727272c2d2e272c2d2e270a0a0a0a0a0a0a270d31272727272727300d2c272727272727272727272727272727210d21272727272728282829282829282828272727"
      "0d07070717393939393939170707070d0d3636202634353636323321212626272727272727272727272727272727272721272727272727272721272727272727273c3d3e273c3d3e2721272721272721270d26212127272731200d3c272727272727272727272727272727210d21272727272721212727212127272121272727"
      "2817171739393939393939391717172828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928282829282828292828282928"
      "3939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939"
      "1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c")
    (p8-section sfx
      "0e0404080c4700c1700c1700c1700c1700c1700c1700c170001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100"
      "010c00000c8500b8310a811188500080000800168500080000050000000005000000000500000000050000000c8500b8310a81118850008001885016850000000c0500000000050000000c050000000005000000"
      "030c000024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c620246353c6553c6353c6253c6353c6553c6353c625"
      "010c00000c8500b8310a811188500080000800168500000002050009000e0500c90002050000000e050000000f8500e8310d8111b85000800008001a850000000505000000110500000005050000001105000000"
      "010c00002455024530245100c5000c5000c50023550245502655026530265100c5000c5000c50024550265502755027530275100c5000c5000c500265502455022550225302251029554295550c5003055430555"
      "010c00002b5542b5522b5422b5322b5222b5150c5020c5020c5020c5020c5020c5020c5020c5002b52429555275550c5020c5020c5020c5000c5000c5000c50026554265550c50027554275550c5002655426555"
      "010c00002455024530245100c5000c5000c50023550245502655026530265100c5000c5000c50024550265502755027530275100c5000c5000c500265502755029550295302951027554275550c5002955429555"
      "010c00002b5542b5522b5422b5322b5222b5152b5540c5022b5540c5042b5540c5042b5540c5042b554000042b554000042b554000042b554000042b554000042b5540000400004000042f554000043055430552"
      "010c0000245542455224542245322452224515245540c502245540c504245540c504245540c50424554005042355400504235540050423554005042355400504235540050400504005042b554005042b5542b552"
      "010c00000c850008000c85018850008001885016850008000c850008000c85018850008001885016850008000a850008000a85016850008001685014850008000a850008000a8501685000800168501485000000"
      "010c000030552305422f5312e5212d5112c51100000000002455224555000003055230555000002e5542e5522e5522e5422d5312c5212b5112a51100000000002255222555000002e5522e555000002c5542c552"
      "010c00002b5522b5422a53129521285112751100000000001f5521f555000002b5522b55500000295542955229552295422853127521265112551100000000001d5521d555000002955229555000002755427552"
      "010c000008850008000885014850008001485013850008000885000800088501485000800148501385000800078500080007850008000785000800078500080007850008000b850008000e850008001185000000"
      "010c00002c5522c5422b5312a521295112851100000000002055220555000002c5522c555000002b5542b5522b5522b5252c5542c5502b5502b5252c5502c5252b5502b525000002b0002f5512f5553055430552"
      "010c000027552275422653125521245112351100000000001b5521b55500000275522755500000265542655226552265252755427550265502652527550275252655026525000002b0002b5512b5552b5542b552"
      "010c0000088500080008850148500080014850138500080008850008000885014850008001485016850008000a850008000a85016850008001685014850008000a850008000a8501685000800168501785000000"
      "010c00002c5522c5422b5312a521295112851100000000002055220555000002c5522c555000002e5542e5522e5522e5250000000000000000000000000000002b5522b555000002f5522f555000003555235555"
      "010c000027552275422653125521245112351100000000001b5521b55500000275522755500000295542955229552295250000000000000000000000000000002655226555000002b5522b555000002f5522f555"
      "010c00000c850008000c850188500c800188500c850008000b850008000b850178500b800178500b850008000a850008000a850168500a800168500a850008000985001800098501585009800158500985001800"
      "050c000033752337423273131721307112f711327523275533752337553275232755337523375532752327513375133755327523275530752307552b7542b7522b7322b7222b7150070000700007000070000700"
      "090c000030752307422f7312e7212d7112c7112b7522b7552b7522b7552b7522b7552b7522b7552b7522b7512b7512b7552b7522b7552b7522b75527754277522773227722277150070000700007000070000700"
      "010c0000088500080008850148500880014850088500080007850008000785013850078001385007850008000e850028000e8501a8500e8001a8500e850028000c850008000c850178500b800178500b85000000"
      "030c000024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c6253c600000003c6303c62500000000003c6303c6253c6353c65524635246253c6553c6552465524655"
      "050c000033752337423273131721307112f7113275232755337523375532752327553375233751357513573235722357153375433732337223371532754327323272232715337543373233722337150070000700"
      "090c000030752307422f7312e7212d7112c7112b7522b7552c7522c7552b7522b7552c7522c75132751327323272232715307543073230722307152f7542f7322f7222f715307543073230722307150070000700"
      "010c0000088500080008850148500880014850088500080008850018000885014850058001485008850018000a850008000a850168500c800168500a850008000a8500a8500c8001385013850178001785017850"
      "050c00002c7522c7422b7312a721297112871100700007002075220755007002c7522c755007002e7542e7522e7522e7250070000700007000070000700007002b7522b755007002f7522f755007003575235755"
      "090c0000277522774224750247501f7501f7502475024750277522775500700277522775500700267542675226752267250070000700007000070000700007002375223755007001f7521f755007001a7521a755"
      "010c00000c8500c8000c8500c8000c8500c8000c8500c8000c8500c8100c8500c8100c8500c8100c8500c8100c8500c8300c8500c8300c8500c8300c8500c8300a8500a820008000a8500a820008000c8500c820"
      "030c000024630180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c62024635180003c6303c6202463500000000002463500000000003c6303c625"
      "090c00000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005002e5502e522005002e5502e522005003055030522"
      "090c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000267502672000000267502672000000277502772500000"
      "00020000082700b3700f4701367027670052600f6600b350156500e653042430d6430363308623006130000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000200000a4700f6701e670022600d650044400762000420026200e603042030d6030360308603006030000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00060000272501c250142501b250152500e250102500825004250022500125000250002500025000250002400024000230002300022000210002100020000200002000020000200002000020000200002003e200"
      "0003000019250132500f2500b25007250042500225001240002400024000240002300022000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0001000022650156003e650040500f6500b0300761004600046000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000200000b577121713d672004761d67400277017731c66601162226500174519646012302163501637216361c6340143019627002261b6220e6110f6150021603612026130c2040630702502026030a40605704"
      "000300001e55020750235502375000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500"
      "000100000c15515003000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0010000011150101500f1500a15009150081500215001150001500015000140001400012000110001000010000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010400001f05026050000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00060000180501c0501f0502405224000240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000400000e5500b500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500"
      "000400003c0002b1502d160251301b1501415015150191501b1501f0001e0002000000000280002b0002a0002c0002f00033000372002c20001200042000020000200012003d20038200312002a200272002b700"
      "1b0700002f25021250272501b25022250122501a2400c24014240062400d230012300623000230002300020007650002000365000200026500020007650002000265000200002000c65000200056500165000200"
      "000300001d0502205005000050000400003000030003d000230001d00018000260000d0000c0001700012000110002a000330003300015000280001b000370001f0001a0001700023000100001d0001700018000"
      "000200001c65017600156001360000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000900000b573121713d672004761d67400277017731c66601162226500174519646012302163501637216361c6340143019627002261b6230e6130f613002130361302603072030460306203046030620304603"
      "090c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002675026720000002675026720000002775027725"
      "900200000560204602066020560206602036020000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002"
      "900200000564204612066320562206622036220000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002000020000200002"
      "0002000008270342700f4700357027670045600f6602e250156500e653035430d643036332622300613005202340021400202201f4001e4000c2102c3002c3000000000000000000000000000000000000000000"
      "00010000121600a1600446004460044601665003450034400244009640034400145001450014500340014400034000b4000040000400004000040000400004000040000400004000040000400004000040000400")
    (p8-section music
      "00 01023232"
      "00 01023232"
      "01 03020432"
      "00 01020532"
      "00 03020632"
      "00 03020708"
      "00 09020a0b"
      "00 0c020d0e"
      "00 09020a0b"
      "00 0f021011"
      "00 09020a0b"
      "00 0c020d0e"
      "00 09020a0b"
      "00 0f021011"
      "00 12021314"
      "00 15161718"
      "00 12021314"
      "02 19021a1b"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "04 1c1d1e31"
      "01 01424344"
      "02 03424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "00 41424344"
      "01 252a4344"
      "02 5f424344"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a2d2d2020202020202d2d20626972647320776974682067756e73202d2d0a2d2d627920796f6c776f6f636c65202620676f7573706f7572640a2d2d65787472612063726564697473203a6e6f74676f796f6d650a2d2d6d757369633a2073696d6f6e20742e0a0a2d2d626972642069646561730a2d2d63726f772c6f776c2c726176656e2c70656c6963616e2c676f6f73652c0a2d2d636f6c696272692c64696e6f736175722c636f636b617469656c0a2d2d706561666f776c0a0a2d2d2032303233")
    (hex 256 "2d30322d303520737465616c74682070617463682062790a2d2d207a657020746f2066697820302e322e356720627265616b6167650a2d2d20286e657374656420636f6d6d656e7473206e6f206c6f6e6765720a2d2d20737570706f72746564290a0a64656761706c7573203d20300a0a66756e6374696f6e205f696e697428290a096b6579626f617264203d2066616c73650a09696e697467756e7328290a09656e656d6965732c636865636b6572203d207b7d2c7b7d0a092d2d6d6f7573650a096d782c6d793d302c3020200a090a092d2d666c6167730a09736f6c69642c627265616b61626c652c737061776e61626c652c6c6f6f7461626c652c6e6f")
    (hex 512 "7462756c6c6574736f6c69643d302c312c322c332c340a090a092d2d63616d6572610a097368616b652c63616d792c63616d782c74617267657463616d783d302c302c302c300a090a0963616d5f666f6c6c6f775f706c617965723d747275650a2d2d09747261696e70616c203d207b7b382c327d2c7b31312c337d2c0a2d2d097b372c31337d2c7b31322c31337d2c7b31302c397d2c7b302c327d7d0a090a092d2d207a65703a0a09747261696e70616c203d2073706c697422382c322c31312c332c372c31332c31322c31332c31302c392c302c322c382c32220a090a0970616c5f6e2c6d656e75203d20312c226d61696e220a090a096163746f727320")
    (hex 768 "3d207b7d0a09696e69745f656e656d69657328290a09696e69745f706c6179657228313131290a090a09696e69745f70746328290a09776c2c6469666669203d20342c32300a090a092d2d7761676f6e206c656e6774680a097761676f6e5f6e2c747261696e6c656e203d20302c360a09746c203d20747261696e6c656e0a090a0967656e5f747261696e28290a097570646174655f726f6f6d28290a0972616e646f6d2c656e656d696573203d207b7d2c7b7d0a09706172636f75726d617028290a090a0964726f70733d7b7d0a090a09696e69745f6d656e757328290a090a096269726463686f6963652c686172646d6f646574696d65723d302c300a09")
    (hex 1024 "6f66736574626f73732c62756c6c6574735f73686f6f7465642c62756c6c6574735f686974203d20302c312c310a090a0973746174733d7b0a092074696d653d302c0a09206b696c6c733d302c0a09207761676f6e3d302c0a097d0a090a0969735f626f7373203d2066616c73650a09626f73735f706f73203d207b302c307d0a0977696e2c77696e74696d6572203d2066616c73652c300a090a092d2d6461726b657220626c75650a092d2d70616c28312c3133302c31290a092d2d70616c28312c3132392c31290a0970616c28290a09706f6b65283078356632652c31290a090a096c6f63616c2073203d20737461742836290a0969662073203d3d2022")
    (hex 1280 "2d220a096f722073203d3d202222200a096f722073203d3d206e696c207468656e0a09096d656e753d226d61696e220a09656c73650a09096d656e753d2267616d65220a09096269726463686f6963653d746f6e756d2873746174283629290a0909626567696e5f67616d6528290a09656e640a090a656e640a0a66756e6374696f6e205f757064617465363028290a096d6f7573655f785f7928290a09666f7220693d3078333130302c30783331343820646f0a09092d2d6f6e0a0909706f6b6528692c7065656b2869292630623130313131313131290a09656e640a090a0a09696620686172646d6f646574696d6572203e20393020616e64200a096d65")
    (hex 1536 "6e75203d3d20226d61696e2220616e6420646966666920213d203137207468656e0a0909736678283434290a09097368616b652c6469666669203d20352c31370a090964656761706c7573203d20310a0909696e697467756e7328290a0909696e69745f656e656d69657328290a09656e640a0a09677261737374696c6528290a0969662877696e292077696e74696d6572202b3d20310a0969662077696e74696d6572203d3d20313830207468656e0a09096d656e753d2277696e22200a09097365745f737461747328290a09656e640a092d2d69662877696e74696d65723d3d31383029736678283436290a096966206d656e75203d3d202267616d6522")
    (hex 1792 "207468656e0a090964656c636865636b657228290a09090a09097570646174655f64726f707328290a0909706c617965725f75706461746528290a09090a0909666f72206120696e20616c6c286163746f72732920646f0a0909092d2d6163746f727320617265206a7573742062756c6c6574730a090909613a75706461746528290a0909090a090909696620612e64657374726f795f666c6167207468656e0a09090909696620612e646d67203d3d2030207468656e0a0909090909616e696d6578706c6f2861290a090909090967756e732e6578706c6f73696f6e3a6669726528612e782d612e64782a322c612e792d612e64792a322c31290a09090909")
    (hex 2048 "656c7365696620612e646d67203d3d20302e31207468656e0a09090909092d2d66697265776f726b206c61756e636865720a0909090909666f7220693d312c313020646f0a090909090909736678283332290a09090909090967756e732e6d616368696e6567756e3a73686f6f7428612e782d612e64782a322c612e792d612e64792a322c692f3130290a0909090909656e640a09090909656e640a0909090964656c286163746f72732c61290a090909656e640a0909656e640a09090a09092d2d666f72206520696e20616c6c28656e656d6965732920646f0a0909097570646174655f656e656d792865290a0909092d2d696628652e64657374726f795f")
    (hex 2304 "666c61672964656c28656e656d792c65290a09092d2d656e640a09090a0909666f722070746320696e20616c6c287061727469636c65732920646f0a0909097570646174655f70746328707463290a0909096966287074632e64657374726f792964656c287061727469636c65732c707463290a0909656e640a09090a09097570646174655f646f6f7228290a09090a09092d2d7368616b65203d20300a09090a09097570646174655f63616d65726128290a09656c73656966206d656e75735b6d656e755d207468656e0a09096c6f63616c206d203d206d656e75735b6d656e755d0a09096d2e757064617465286d290a09097370726d73203d203132370a")
    (hex 2560 "09656e640a090a097368616b65203d206d617828302c7368616b652d302e33290a090a096c6f63616c207478743d6b6579626f61726420616e6420226b6579626f61726422206f7220226d6f7573652b6b657973220a096d656e756974656d28332c226d6f64653a222e2e7478742c2066756e6374696f6e2829206b6579626f617264203d206e6f74206b6579626f61726420656e64290a096d656e756974656d28322c22e28c82206d61696e206d656e75222c2066756e6374696f6e28292072756e28222d222920656e64290a090a096966202862746e28e29d8e29206f722062746e28f09f85beefb88f2929206b6579626f617264203d2074727565200a")
    (hex 2816 "09696620286c6d6229206b6579626f617264203d2066616c73650a656e640a0a0a66756e6374696f6e205f6472617728290a096c6f63616c206f78203d2072726e64287368616b65290a096c6f63616c206f79203d2072726e64287368616b65290a092d2d696620286b6579626f617264203d3d207472756529200a0963616d6572612863616d782b6f782c2063616d792b6f79290a090a09636c73283135290a090a092d2d64726177206d61700a0964726177677261737328290a090a09647261775f6d617028290a096966207761676f6e5f6e3d3d3020616e64206d656e753d3d2267616d6522207468656e0a09096c6f63616c20733d205b5b0a2020e2")
    (hex 3072 "ac86efb88f20202020202020205b655d0ae2ac85efb88fe2ac87efb88fe29ea1efb88f206f72205b73206420665d200a20202020206d6f7665200a0a5b636c69636b5d202073686f6f740a5b7363726f6c6c5d206368616e6765200a20202020202020202020776561706f6e0a09095d5d0a09096966286b6579626f61726429733d5b5b0a20202020e2ac86efb88f0a2020e2ac85efb88fe2ac87efb88fe29ea1efb88f206d6f7665200a0a2020e29d8e202878292073686f6f740a2020f09f85beefb88f20286329206368616e6765200a202020202020202020776561706f6e0a09095d5d0a09097072696e7428732c33332c34322c32290a09656e640a0a")
    (hex 3328 "09647261775f7765656c28290a090a09647261775f64726f707328290a090a09666f72206520696e20616c6c28656e656d6965732920646f0a0909647261775f656e656d792865290a09656e640a09647261775f706c6179657228290a090a09666f72206120696e20616c6c286163746f72732920646f0a0909613a6472617728290a09656e640a090a09666f722070746320696e20616c6c287061727469636c65732920646f0a0909647261775f70746328707463290a09656e640a090a096966286d656e75213d226d61696e2229647261775f706c617965725f75692870290a090a096c6f63616c206d203d206d656e75735b6d656e755d0a096966206d")
    (hex 3584 "207468656e0a09096d2e64726177286d290a09656e640a090a092d2d3e3e6e6f20636f64652062656c6f7720746869733c3c2d2d0a092d2d64726177206d6f7573650a090a096966286e6f74206b6579626f617264206f72206d656e753d3d2267616d652229737072287370726d732c6d782d312c6d792d31290a0970616c28312c3132392c31290a656e640a0a2d2d2d2d2d2d2d2d2d2d0a66756e6374696f6e207365745f737461747328290a0973746174732e74696d653d666c72280a09202874696d6528292d73746174732e74696d6529202a20313029202f2031300a096c6f63616c2074203d2073746174732e74696d650a096c6f63616c2073203d")
    (hex 3840 "2022220a0969662874253630203c2031302920733d2230220a0973746174732e74696d653d20746f73747228745c3630292e2e223a222e2e732e2e746f737472287425363029200a092d2d73746174732e74696d653d28666c722873746174732e74696d65295c3630292b2828666c722873746174732e74696d65292d28666c722873746174732e74696d65295c3630292a3630292f313030290a0973746174732e7761676f6e3d746f737472287761676f6e5f6e2b31292e2e222f37220a656e640a0a66756e6374696f6e20626567696e5f67616d6528290a09736678283337290a096d7573696328290a090a096c6f63616c20623d6269726463686f6963")
    (hex 4096 "65206f7220300a0969662062203d3d2030207468656e0a0909623d666c7228726e6428313229292b310a09656e640a09696e69745f706c61796572283131312b62290a090a0973746174732e74696d65203d2074696d6528290a090a09702e782c702e79203d2034382c35360a090a097368616b65202b3d20370a09666f7220693d312c313020646f0a09096d616b655f707463280a0909203438202b2072726e642838292c0a0909203536202b2072726e642838292c0a090920382b726e642838292c726e64287b322c342c367d292c302e39372c0a09092072726e642832292c72726e642832290a0909290a09656e640a656e640a0a66756e6374696f6e")
    (hex 4352 "2069736c6566742861290a0972657475726e20613c2e373520616e64202e32353c610a656e640a0a66756e6374696f6e206f73707228732c782c792c636f6c290a09666f7220693d302c313520646f0a090970616c28692c636f6c290a09656e640a090a09666f7220693d2d312c31646f0a0909666f72206a3d2d312c31646f0a09090973707228732c782b692c792b6a290a0909656e640a09656e640a090a0970616c28290a0973707228732c782c79290a656e640a0a66756e6374696f6e206f7072696e7428742c782c792c636f6c2c6f636f6c290a096c6f63616c206f636f6c203d206f636f6c206f7220310a09666f7220693d2d312c31646f0a0909")
    (hex 4608 "666f72206a3d2d312c31646f0a0909097072696e7428742c782b692c792b6a2c6f636f6c290a0909656e640a09656e640a090a096c6f63616c20636f6c203d20636f6c206f7220370a097072696e7428742c782c792c636f6c290a656e640a0a66756e6374696f6e20636f70792874290a096c6f63616c206e3d7b7d0a09666f72206b2c7620696e20706169727328742920646f0a09096e5b6b5d203d20760a09656e640a0972657475726e206e0a656e640a0a66756e6374696f6e207570646174655f63616d65726128290a096c6f63616c207078203d20702e780a096c6f63616c20776c203d20776c0a096c6f63616c206d61786c656e203d203234300a")
    (hex 4864 "090a092d2d706f6b65283078356634302c30290a09706f6b65283078356634332c30290a096966207078203e203132382a28776c2d31292b38207468656e0a09092d2d70616e2063616d20746f20636f6e6e6563746f7220726f6f6d0a090963616d5f666f6c6c6f775f706c617965723d66616c73650a090974617267657463616d783d3132382a28776c2d31290a09090a09092d2d626c6f636b206f6666206f6c6420656e7472616e63650a09096966207761676f6e5f6e20213d20746c2d31207468656e0a0909092d2d6d7365742834382c372c36290a0909092d2d6d7365742834382c362c3133290a0909656e640a09090a09092d2d6c6f772d706173")
    (hex 5120 "732066696c746572202620736c6f770a09092d2d706f6b65283078356634302c3135290a09096966287761676f6e5f6e213d746c29706f6b65283078356634332c3135290a09656e640a0969662063616d5f666f6c6c6f775f706c61796572207468656e200a09092d2d63616d65726120666f6c6c6f777320706c617965720a090963616d78203d2070782d36300a09092d2d6f66667365742063616d65726120746f20637572736f720a09096966206e6f74206b6579626f617264207468656e0a090963616d78202b3d202873746174283332292d3634292f330a0909656e640a090963616d78203d206d696428302c2063616d782c203132382a28776c2d")
    (hex 5376 "32292b3829205c20310a090963616d79203d20300a09656c73650a09092d2d646f206120636f6f6c20616e696d6174696f6e0a090963616d783d6365696c280a09092063616d782b2874617267657463616d782d63616d78292f3130290a09090a090969662074617267657463616d78203c3d20300a0909616e64206365696c2863616d78293d3d74617267657463616d78207468656e0a09090963616d5f666f6c6c6f775f706c617965723d747275650a0909656e640a09656e640a656e640a0a66756e6374696f6e20647261775f67686f73745f636f6e6e6563746f7228290a0969662063616d783c30207468656e0a09096d617028302c31362c202d31")
    (hex 5632 "32382c302c2031362c3136290a09656e640a656e640a0a66756e6374696f6e2072726e64286e290a092d2d2272616469757320726e64220a0972657475726e20726e6428322a6e292d6e0a656e640a0a66756e6374696f6e20616c6c62746e2862290a0972657475726e2062746e286229206f722062746e28622c31290a656e640a0a2d2d5b5b0a66756e6374696f6e2064656275675f28290a096c6f63616c2070203d706c61796572735b315d0a09702e67756e6c735b315d203d20646562756767756e0a097761676f6e5f6e203d20746c2d310a09666f72206920696e20616c6c28656e656d69657329646f200a0909692e646573746f7279203d207472")
    (hex 5888 "75650a09656e640a09702e6d61786c696665203d2031303030300a09702e6c696665203d2031303030300a656e642d2d5d5d0a0a2d2d3e380a2d2d706c617965720a66756e6374696f6e20696e69745f706c617965722862697264290a09623d300a096478313d310a096479313d300a0970203d207b0a09096e3d312c0a09096167726f203d20393939392c0a0909783d2d36342c793d2d36342c0a090964783d302c64793d302c0a0909613d302c0a09090a09097370643d2e342c0a0909667269633d302e37352c0a09090a090962783d322c62793d322c0a090962773d342c62683d342c0a09090a090968783d322c68793d322c0a090968773d342c0a09")
    (hex 6144 "090a09096c6966653d31302c0a09096d61786c6966653d31302c0a0909616d6d6f3d3235302c0a09096d6178616d6d6f3d3235302c0a09090a09097370723d626972642c0a09090a090967756e3d6e696c2c0a090967756e6e3d312c0a090967756e6c733d7b7d2c0a090a09096c6d6270203d20747275652c0a0909696672616d65733d33302c0a09090a090964616d6167653d64616d6167655f706c617965722c0a09097370726974656f6666736574203d20302c0a09096b616b203d20636f7079286b616b290a097d0a0a09702e67756e203d20702e67756e6c735b315d0a0a092d2d73686f756c64207765206b656570207468697320696e3f20626972")
    (hex 6400 "642073746174730a0a096c6f63616c206e203d20626972642d3131310a096c6f63616c20626972645f73746174733d73706c69745b5b6e2c2020202020312c2020322c2020332c2020342c2020352c2020362c2020372c2020382c2020392c202031302c2031312c2031320a2c6c6966652c20202031302c2031302c20352c202031302c2031302c2031302c2031302c2031302c2031302c20322c202031302c2031300a2c6d61786c6966652c31302c2031302c20352c202031302c2031302c2031302c2031302c2031302c2031302c2031352c2031302c2031300a2c7370642c202020202e342c202e342c202e342c202e342c202e342c202e342c202e342c")
    (hex 6656 "202e342c202e35352c202e342c202e342c202e340a2c667269632c2020202e37352c2e37352c2e37352c2e37352c2e37352c2e37352c2e37352c2e37352c2e37352c2e37342c2e37352c2e37350a5d5d0a09666f7220693d312c23626972645f73746174732c313320646f0a0909705b626972645f73746174735b695d205d203d20626972645f73746174735b692b6e5d0a09656e640a092d2d2020202020202020202020202020202020202020202020205b2020202064656661756c74202020205d5b2020202020706967656f6e202020205d5b202020202020206475636b2020202020202020205d5b20202020202020202073706172726f772020202020")
    (hex 6912 "202020202020205d5b20202020202020202020706172726f74202020202020202020205d5b20202020746f7563616e2020202020202020205d5b2020202020666c616d696e676f2020205d5b2020202020202020206561676c652020202020202020202020205d5b2020202073656167756c6c202020202020205d5b2020202020206f73747269636820202020205d5b2020202070656e6775696e20205d5b2020202020206a617920202020202020202020205d5b2020202020636869636b656e202020205d200a096c6f63616c20626972645f776561706f6e733d73706c6974227265766f6c7665722c73686f7467756e2c7265766f6c7665722c73686f74")
    (hex 7168 "67756e2c7265766f6c7665722c666c616d657468726f7765722c626f78696e675f676c6f76652c66697265776f726b6c61756e636865722c6d616368696e6567756e2c66697265776f726b6c61756e636865722c626f78696e675f676c6f76652c73686f7467756e2c7265766f6c7665722c72696e6763616e6e6f6e2c626f78696e675f676c6f76652c61737361756c747269666c652c6d616368696e6567756e2c736e697065722c6d616368696e6567756e2c6761746c696e6767756e2c73686f7467756e2c736e697065722c73686f7467756e2c61737361756c747269666c652c7265766f6c7665722c62617a6f6f6b61220a090a09666f7220693d312c")
    (hex 7424 "3220646f0a0909702e67756e6c735b695d203d20636f70792867756e735b626972645f776561706f6e735b322a6e2b695d205d290a09656e640a090a097570646174655f67756e2870290a656e640a0a66756e6374696f6e20706c617965725f75706461746528290a09202d2d64616d6167650a0920702e696672616d6573203d206d617828302c702e696672616d65732d31290a09092d2d6d6f76656d656e740a09096c6f63616c2064782c6479203d20702e64782c702e64790a09096c6f63616c20737064203d20702e7370640a09090a090969662028616c6c62746e28e2ac85efb88f292920702e64782d3d737064206478312d3d7370640a09096966")
    (hex 7680 "2028616c6c62746e28e29ea1efb88f292920702e64782b3d737064206478312b3d7370640a090969662028616c6c62746e28e2ac86efb88f292920702e64792d3d737064206479312d3d7370640a090969662028616c6c62746e28e2ac87efb88f292920702e64792b3d737064206479312b3d7370640a09090a09092d2d35380a09090a0909702e6478202a3d20702e667269630a0909702e6479202a3d20702e667269630a09090a20206966202861627328647831292b6162732864793129293e302e31207468656e0a0909647831202a3d20702e667269630a0909647931202a3d20702e667269630a0909656e640a09090a0909636f6c6c69646528702c")
    (hex 7936 "302e31290a09090a0909702e78202b3d20702e64780a0909702e79202b3d20702e64790a09090a09090a09092d2d616e696d6174696f6e0a09090a090969662061627328702e6478292b61627328702e6479293e302e373520207468656e0a090920616e696d706c617965722870290a0909656c7365200a090909702e7370726974656f6666736574203d20300a0909656e640a09090a09092d2d61696d696e670a09096966206b6579626f617264207468656e0a0909097370726d733d37360a090909646973746d696e3d393939390a090909696e6465786d696e696e69743d7b783d702e782d6f66736574626f73732b6478312c793d702e792d6f667365")
    (hex 8192 "74626f73732b6479317d0a090909696e6465786d696e3d696e6465786d696e696e69740a090909666f72206520696e20616c6c28656e656d6965732920646f0a09090920096966206c6f6164656428652920616e64200a090909200963616e73686f6f7428702c6529207468656e0a09090909096c6f63616c2064697374203d206469737428702c65290a090909090969662028646973746d696e3e646973742920646973746d696e3d6469737420696e6465786d696e3d650a09090909656e640a090909656e640a0a0909096f66736574626f7373203d20300a090909696628696e6465786d696e2e737072203d3d203129206f66736574626f7373203d20")
    (hex 8448 "340a0a090909702e61203d206174616e3228696e6465786d696e2e782b6f66736574626f73732d702e782c0a090909696e6465786d696e2e792b6f66736574626f73732d702e79290a0909096d783d696e6465786d696e2e782b312b6f66736574626f73730a0909096d793d696e6465786d696e2e792b312b6f66736574626f73730a090909696628696e6465786d696e3d3d696e6465786d696e696e6974297370726d733d35370a0909656c73650a0909097370726d73203d203132370a090909702e61203d206174616e32286d782d702e782c0a0909096d792d702e7929090a0909656e640a0909702e666c6970203d2069736c65667428702e61290a09")
    (hex 8704 "090a09092d2d616d6d6f2026206c6966650a0909702e6c6966653d6d696e286d617828302c702e6c696665292c702e6d61786c696665290a0909702e67756e2e616d6d6f3d6d696e286d617828302c702e67756e2e616d6d6f292c702e67756e2e6d6178616d6d6f290a09090a09092d2d64656174680a0909696620702e6c696665203c3d2030200a0909616e64206d656e75213d226465617468227468656e0a090909736678283334290a0909096d75736963282d312c20333030290a0909090a0909096d656e75203d20226465617468220a0909097368616b65202b3d20390a09090962757273745f70746328702e782b342c702e792b342c37290a0909")
    (hex 8960 "090a0909097365745f737461747328290a0909656e640a09090a09092d2d73686f6f74696e670a09096966207374617428333629203d3d31206f72207374617428333629203d3d2d31206f72202862746e7028f09f85beefb88f2929207468656e0a0909096e65787467756e2870290a0909092d2d7072696e7428702e67756e2e636f6f6c646f776e2c302c30290a090909702e67756e2e74696d6572203d20702e67756e2e636f6f6c646f776e2f320a0909656e640a09090a09090a09096c6f63616c20666972653d6c6d62206f722062746e28e29d8e29200a09096c6f63616c206163746976653d726d620a09090a09096c6f63616c20646f666972650a")
    (hex 9216 "09090a0909702e6b616b3a75706461746528290a0909702e67756e3a75706461746528290a090974657374203d20702e67756e2e6e616d650a09092d2d206e6f74206175746f0a09096966206669726520616e640a0909702e67756e2e74696d65723c3d3020616e640a0909702e67756e2e616d6d6f203e203020616e6420702e67756e2e6175746f203d3d2066616c73650a09097468656e0a090909696620702e6c6d6270203d3d2074727565207468656e0a09090909646f66697265203d20747275650a090909090a09090909702e6c6d6270203d2066616c73650a090909656e640a0909090a09092d2d206175746f0a0909656c736569662066697265")
    (hex 9472 "20616e6420702e67756e2e74696d65723c3d30200a0909616e6420702e67756e2e616d6d6f203e2030207468656e0a090909646f66697265203d20747275650a0909656c73656966206669726520616e640a2020202020202020702e67756e2e616d6d6f203c203120616e640a2020202020202020702e6c6d6270203d3d207472756520616e640a2020202020202020702e6b616b2e74696d65723c3d30207468656e0a2020202020202020636f757064656b616b287029200a2020202020202020702e6c6d6270203d2066616c73650a0909656e640a09090a0909696620646f66697265207468656e0a0909096d616b655f70746328702e782b636f732870")
    (hex 9728 "2e61292a362b342c200a09090909702e792b73696e28702e61292a332b342c20726e642833292b362c372c2e37290a090909090a090909702e67756e2e616d6d6f202d3d20310a090909702e67756e3a6669726528702e782b342c702e792b342c702e61290a0909656e640a09090a09092d2d206966206d6c656674206e6f742070726573736564200a09096966206e6f742066697265207468656e0a090909702e6c6d6270203d20747275650a0909656e640a09090a09092d2d626567696e20626f73730a09096c6f63616c2077333d3132382a28776c2d31290a09090a09096966207761676f6e5f6e3d3d746c20616e6420702e783e7733200a0909616e")
    (hex 9984 "642063616d5f666f6c6c6f775f706c61796572200a0909616e64206e6f742069735f626f7373207468656e0a09090969735f626f7373203d20747275650a090909626567696e5f626f737328290a090909702e78203d2077332b380a0909656e640a09090a09092d2d6e657874207761676f6e0a0909696620702e783e3132382a776c207468656e0a09090972616e646f6d203d207b7d0a0909090a0909097761676f6e5f6e202b3d20310a0909097570646174655f726f6f6d28290a090909656e656d696573636c65617265643d66616c73650a09090970616c5f6e202b3d20310a0909090a0909092d2d70616e2063616d20746f206e657874207761676f")
    (hex 10240 "6e0a09090963616d78203d202d3132380a09090974617267657463616d783d300a09090964726f7073203d207b7d0a090909656e656d696573203d207b7d0a090909706172636f75726d617028290a0909092d2d74656c65706f727420706c61796572730a090909702e78202d3d203132382a776c0a090909702e78203d206d617828702e782c2030290a0909656e640a0909666f72206520696e20616c6c28656e656d69657329646f0a0909090a090909696620746f75636865735f72656374280a090909702e782b342c702e792b342c0a090909652e782b312c652e792b312c652e782b372c652e792b3729207468656e0a090909090a09090909696620")
    (hex 10496 "28702e696672616d6573203d3d203029207468656e0a0909090909736678283335290a09090909096966287368616b653c3d32297368616b65202b3d20320a0909090909696620652e73707220213d20313236207468656e0a090909090909702e6c6966652d3d312b2864656761706c75732a32290a0909090909656c7365200a090909090909702e6c6966652d3d312b64656761706c75730a0909090909656e640a0909090909702e696672616d6573203d2033300a09090909090a0909090909696620652e737072203d3d20313039207468656e0a090909090920702e6c6966652b3d310a0909090909206b696c6c626172656c6c652865290a09090909")
    (hex 10752 "0920702e696672616d6573203d20300a0909090909656e640a09090909656e640a090909096b6e6f636b6261636b5f706c6179657228702c65290a0909090a090909656e640a0909656e640a656e640a0a66756e6374696f6e20647261775f706c6179657228290a0969662028702e696672616d6573253529203d3d203020207468656e0a09096c6f63616c20783d666c7228702e7829202b20636f7328702e61292a36202b300a09096c6f63616c20793d666c7228702e7929202b2073696e28702e61292a33202b300a09090a0909696620702e67756e2e6e616d653d3d22736e6970657222207468656e0a0909096c6f63616c20632c733d636f7328702e")
    (hex 11008 "61292c73696e28702e61290a0909096c696e65280a090909782b342b632a362c0a090909792b342b732a362c0a090909702e782b632a3132382c0a090909702e792b732a3132382c38290a0909656e640a090973707228702e67756e2e7370722c782c792c312c312c20702e666c6970290a09090a09090a090970616c7428302c66616c7365290a090970616c7428312c74727565290a09090a090973707228702e7370722c702e782c702e792b702e7370726974656f66667365742c312c312c20702e666c6970290a09090a090970616c7428290a09656e640a656e640a0a66756e6374696f6e20647261775f706c617965725f75692870290a092d2d6c69")
    (hex 11264 "666520636f756e7465720a097265637466696c6c2863616d782b312c312c63616d782b34332c372c32290a096c6f63616c206c3d34302a28702e6c6966652f702e6d61786c696665290a097265637466696c6c2863616d782b322c322c63616d782b322b6c2c362c38290a090a096c6f63616c20733d22e299a5222e2e702e6c6966652e2e222f222e2e702e6d61786c6966652e2e2220220a097072696e7428732c2063616d782b322c322c37290a090a092d2d616d6d6f206261720a097265637466696c6c2863616d782b38342c312c63616d782b38342b34322c372c34290a096c6f63616c206c3d34302a28702e67756e2e616d6d6f2f702e67756e2e6d")
    (hex 11520 "6178616d6d6f290a09696628702e616d6d6f3e30297265637466696c6c2863616d782b38352c322c63616d782b38352b6c2c362c39290a090a096c6f63616c20732c636f6c203d20746f73747228702e67756e2e616d6d6f292c370a09696628733d3d2230222920732c636f6c3d226e6f20616d6d6f21222c31340a09737072283131302c63616d782b38392c32290a097072696e7428732c2063616d782b39352c322c636f6c290a090a092d2d776561706f6e206c6973740a09666f7220693d312c3220646f0a09096c6f63616c20636f6c203d20310a0909696628693d3d702e67756e6e29636f6c3d370a09090a09096f73707228702e67756e6c735b69")
    (hex 11776 "5d2e7370722c200a090963616d782b39302b28692d31292a31302c2031302c636f6c290a09656e640a090a092d2d7761676f6e0a096c6f63616c20636f6c6f72203d20370a0969662064656761706c7573203d3d2031207468656e0a0909636f6c6f72203d20380a0909656c736520636f6c6f72203d20370a09656e640a096f7072696e7428227761676f6e20222e2e7761676f6e5f6e2b31202e2e222f37222c0a0963616d782b34362c322c636f6c6f722c31290a092d2d7072696e7428746573742c302c3830290a656e640a0a66756e6374696f6e206e65787467756e2870290a09736678283336290a090a09702e67756e6e202b3d20310a0969662870")
    (hex 12032 "2e67756e6e203e2023702e67756e6c732920702e67756e6e203d20310a097570646174655f67756e2870290a092d2d5b5b6c6f63616c2066203d20300a09666f7220693d312c23702e67756e6c7320646f0a09696620702e67756e6c735b695d203d3d20702e67756e6e207468656e0a0909696620282828692b7374617428333629292523702e67756e6c73293c31292066203d2023702e67756e6c730a09092072657475726e20702e67756e6c735b28692b737461742833362929252823702e67756e6c73292b665d0a0909656e640a09656e645d5d0a656e640a0a66756e6374696f6e207570646174655f67756e2870290a09702e67756e203d20702e67")
    (hex 12288 "756e6c735b702e67756e6e5d0a656e640a0a66756e6374696f6e206b6e6f636b6261636b5f706c6179657228702c65290a0969662061627328702e6478292b61627328702e647929203c2033207468656e0a0909092020702e64782b3d652e64782a652e7370642a320a0909090920702e64792b3d652e64792a652e7370642a320a090909656e64090a656e640a0a66756e6374696f6e206b6e6f636b6261636b5f656e656d7928652c62290a090a09096966202861627328652e6478292b61627328652e64793c33302929207468656e0a090909652e64782b3d622e64782a622e7370642a2e310a090909652e64792b3d622e64792a622e7370642a2e310a")
    (hex 12544 "0909656e640a0a656e640a0a66756e6374696f6e20616e696d706c617965722870290a09696620666c722874696d6528292a372925323d3d31207468656e0a0909702e7370726974656f6666736574203d20310a09656c7365200a0909702e7370726974656f6666736574203d20300a09656e640a656e640a0a66756e6374696f6e20636f757064656b616b2870290a096c6f63616c20783d666c7228702e7829202b20636f7328702e61292a36202b300a096c6f63616c20793d666c7228702e7929202b2073696e28702e61292a33202b300a090a09702e6b616b3a6669726528782b342c792b342c702e61290a656e640a2d2d3e380a2d2d67756e202620")
    (hex 12800 "62756c6c65740a0a66756e6374696f6e206d616b655f67756e28617267732c66697265290a096c6f63616c206e616d655f2c737072722c63645f2c7370642c6f612c646d672c69735f656e656d792c6175746f2c6d6178616d6d6f2c736678782c6b6e6f636b6261636b3d756e7061636b2873706c6974286172677329290a0a090a0969735f656e656d79203d2069735f656e656d79203d3d20310a096175746f203d206175746f20203d3d20310a0969662869735f656e656d792920646d67202b3d2064656761706c7573202a20320a090a092d2d746f646f3a6e6f742068617665203330303020617267730a096c6f63616c2067756e203d207b0a09096e")
    (hex 13056 "616d653d6e616d655f2c0a09097370723d737072722c0a09097370643d7370642c0a09096f613d6f612c2d2d6f666673657420616e676c6520696e205b302c315b0a0909646d673d646d672c0a09097368616b653d7368616b652c0a09096175746f3d6175746f2c0a09090a0909616d6d6f3d6d6178616d6d6f2c0a09096d6178616d6d6f3d6d6178616d6d6f2c0a09090a090974696d65723d302c0a0909636f6f6c646f776e3d63645f2c0a090969735f656e656d793d69735f656e656d792c0a09090a0909783d302c793d302c0a09096469723d302c0a090962757273743d302c0a09090a09097366783d736678782c0a09096b6e6f636b6261636b3d6b")
    (hex 13312 "6e6f636b6261636b2c0a097d0a090a0967756e2e66697265203d20666972650a090a0967756e2e73686f6f743d66756e6374696f6e2867756e2c782c792c6469722c7370642c6b6e6f636b6261636b290a09092d2d72656d6f76653f20697420636f6d706c69636174657320636f64650a090969662867756e2e62757273743c3d30296469722b3d72726e642867756e2e6f61290a09090a090969662867756e2e73667829207366782867756e2e736678290a09090a09096c6f63616c20733d39330a09096c6f63616c206e616d65203d2067756e2e6e616d650a09096c6f63616c2070616c65747465203d2022220a0a090969662867756e2e69735f656e65")
    (hex 13568 "6d7929733d39350a09096966286e616d653d3d226b616b2229733d3737206c69667370613d350a09096966286e616d653d3d22626f78696e6720676c6f76652229732c6c69667370613d37372c31300a09096966286e616d653d3d22666c616d657468726f7765722229206c69667370613d34302070616c657474653d22312c322c332c342c352c362c31302c382c382c39220a09096966286e616d653d3d226578706c6f73696f6e2229733d3537206c69667370613d31300a09096966286e616d653d3d2262617a6f6f6b6122292070616c657474653d22312c322c332c342c352c362c362c382c352c3133220a09096966206e6f742067756e2e69735f65")
    (hex 13824 "6e656d79207468656e0a0909096966287368616b653c3120616e64206e616d65213d22666c616d657468726f77657222297368616b652b3d31200a0909656e640a09090a0909737064203d20737064206f722067756e2e7370640a0909737061776e5f62756c6c657428782c792c6469722c0a09097370642c332c732c646d672c69735f656e656d792c6c69667370612c70616c65747465290a09096c69667370613d6e696c0a090967756e2e74696d6572203d2067756e2e636f6f6c646f776e0a0909702e64782d3d636f7328646972292a67756e2e6b6e6f636b6261636b0a0909702e64792d3d73696e28646972292a67756e2e6b6e6f636b6261636b0a")
    (hex 14080 "09656e640a090a0967756e2e7570646174653d66756e6374696f6e2867756e290a090967756e2e74696d6572203d206d61782867756e2e74696d65722d312c30290a090967756e2e616d6d6f203d206d696428302c67756e2e616d6d6f2c67756e2e6d6178616d6d6f290a09090a090969662067756e2e6275727374203e2030207468656e0a09090967756e3a73686f6f742867756e2e782c67756e2e792c67756e2e646972290a09090967756e2e6275727374202d3d20310a0909656e640a09656e640a090a0972657475726e2067756e0a656e640a0a66756e6374696f6e2073686f6f74312867756e2c782c792c646972290a0967756e3a73686f6f7428")
    (hex 14336 "782c792c646972290a656e640a0a2d2d20696e69742067756e730a0a2d2d64656761706c7573203d20300a202020202020202020202020202020202020202d2d6e616d6520202020202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f20736678206b6e6f636b0a2d2d646562756767756e203d206d616b655f67756e2822646562756767756e2c2036342c20312c20332c202e30322c20302c20302c20202020202020312c2020203939393939392c2036342c2031222c0a2d2d090966756e6374696f6e2867756e2c782c792c646972290a2d2d092020666f7220693d312c3720646f0a2d2d0920090970")
    (hex 14592 "2e6c696665202b3d20310a2d2d0920090967756e3a73686f6f7428782c792c6469722b72726e64282e31292c206f737064290a2d2d092009656e640a2d2d656e640a2d2d090966756e6374696f6e2867756e2c782c792c646972290a2d2d09090967756e3a73686f6f7428782c792c646972290a2d2d0909656e640a2d2d09290a66756e6374696f6e20696e697467756e7328290a67756e73203d207b0a0a20202020202020202020202020202020202020202020202d2d6e616d6520202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a097265766f6c766572203d206d616b655f67756e28")
    (hex 14848 "227265766f6c7665722c2036342c2031352c322e352c2e30322c33202c302c20202020202020302c2020203130302c2020202033332c20302e33222c0a090973686f6f74310a09292c0a090a090a0966697265776f726b6c61756e63686572203d206d616b655f67756e282266697265776f726b206c61756e636865722c2037342c2032352c322e352c2e30322c302e31202c302c20202020202020302c20202038302c2020202035322c20302e36222c0a090973686f6f74310a09292c0a090a09626f78696e675f676c6f7665203d206d616b655f67756e2822626f78696e6720676c6f76652c2037322c2031382c332e332c2e3030352c31202c20302c20")
    (hex 15104 "302c20312c20202020202035332c202d302e3936222c0a2066756e6374696f6e2867756e2c782c792c646972290a2020666f7220693d312c3720646f0a09090967756e3a73686f6f7428782c792c646972290a0909656e640a0909702e696672616d65732c67756e2e616d6d6f203d20392c67756e2e6d6178616d6d6f0a0909656e640a20292c0a090a090a0962617a6f6f6b61203d206d616b655f67756e282262617a6f6f6b612c2036392c2039302c312e352c2e3030372c30202c302c20202020202020302c20202032302c2020202033332c20342e35222c0a090973686f6f74310a09292c0a090a09666c616d657468726f776572203d206d616b655f")
    (hex 15360 "67756e2822666c616d657468726f7765722c2037302c20322c312e352c2e3031352c302e3334202c302c20202020202020312c202020313530302c2020202035312c2030222c0a090973686f6f74310a09292c0a090a0972696e6763616e6e6f6e203d206d616b655f67756e282272696e672063616e6e6f6e2c2020202037312c2034352c322c202e30312c332c2020302c202020302c202035302c2020202033322c2030222c0a092066756e6374696f6e2867756e2c782c792c646972290a092009666f7220693d312c323020646f0a092009096c6f63616c206f3d692f32300a092009096c6f63616c206f7370643d67756e2e7370642a28726e64282e32")
    (hex 15616 "292b2e39290a0920090967756e3a73686f6f7428782c792c6469722b6f2c206f737064290a092009656e640a0920656e64292c0a0920202020202020202020202020202020202020202d2d6e616d652020202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a0973686f7467756e203d206d616b655f67756e282273686f7467756e2c2020202036352c2036302c342c202e30352c312e32352c2020302c202020302c202035302c2020202033322c20302e34222c0a092066756e6374696f6e2867756e2c782c792c646972290a092009666f7220693d312c3720646f0a092009096c6f63616c")
    (hex 15872 "206f3d72726e64282e3035290a092009096c6f63616c206f7370643d67756e2e7370642a28726e64282e32292b2e39290a0920090967756e3a73686f6f7428782c792c6469722b6f2c206f737064290a092009656e640a0920656e64292c0a09200a09202020202020202020202020202020202020202020202020202d2d6e616d6520202020202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a096d616368696e6567756e203d206d616b655f67756e28226d616368696e6567756e2c2036362c20372c20332c202e30352c3220202c302c20202020202020312c203235302c202020203333")
    (hex 16128 "2c202e32222c0a090973686f6f74310a09292c0a090a0920202020202020202020202020202020202020202020202020202d2d6e616d65202020202020202020202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a0961737361756c747269666c65203d206d616b655f67756e282261737361756c74207269666c652c2036372c2033302c342c202e30322c312020202c302c20202020202020312c2037352c20202020202033332c202e33222c0a090966756e6374696f6e2867756e2c782c792c646972290a09090967756e2e6275727374203d20340a09090967756e2e782c2067756e2e79")
    (hex 16384 "203d20782c20790a09090967756e2e646972203d6469722b2872726e64283129292a67756e2e6f610a09090967756e3a73686f6f7428782c792c67756e2e646972290a0909656e640a09292c0a090a09202020202020202020202020202020202020202d2d6e616d65202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a09736e69706572203d206d616b655f67756e2822736e697065722c2036382c2034302c372c202e302c203520202c302c2020202020202020302c202033352c202020202033322c2033222c0a090973686f6f74310a09292c0a090a0920202020202020202020202020")
    (hex 16640 "2020202020202020202020202020202d2d6e616d65202073707220636420737064206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366782020206b620a096761746c696e6767756e203d206d616b655f67756e28226761746c696e672067756e2c2037332c20332c20332c202e30382c203220202c302c2020202020202020312c20203530302c202020202033332c2031222c0a090973686f6f74310a09292c0a090a09202020202020202020202020202020202020202020202d2d6e616d652020202020207370722063642020737064206f61202020646d672069735f656e656d79206175746f206d6178616d6d6f2073667820")
    (hex 16896 "6b620a0967756e736c696d65203d206d616b655f67756e282267756e736c696d652c2036342c203130302c312e352c202e30322c322c2020312c20202020202020312c2020203235302c2020202033322c2030222c0a090966756e6374696f6e2867756e2c782c792c646972290a0909096469722b3d72726e642867756e2e6f61290a09090967756e3a73686f6f7428782c792c646972290a0909656e640a09292c0a090a2020202020202020202020202020202020202020202020202020202020202d2d6e616d65202020202020737072206364207370642020206f6120646d672069735f656e656d79206175746f206d6178616d6d6f207366780a096775")
    (hex 17152 "6e736c696d6562756666203d206d616b655f67756e282267756e736c696d65627566662c2036342c203130302c312c202e30342c322c2020312c20202020202020312c2020203235302c2033322c2030222c0a090966756e6374696f6e2867756e2c782c792c646972290a090909666f7220693d302c3220646f0a090909096c6f63616c206f3d72726e64282e3035290a090909096c6f63616c206f7370643d67756e2e7370642a28726e64282e32292b2e39290a0909090967756e3a73686f6f7428782c792c6469722b6f2c206f737064290a090909656e640a0909656e640a09292c0a090a090a0973686f7467756e6d656368616e74203d206d616b655f")
    (hex 17408 "67756e282273686f7467756e6d656368616e742c2036352c2036302c312e33352c202e30342c332c20312c20312c203235302c2033322c2030222c0a090966756e6374696f6e2867756e2c782c792c646972290a09200909666f7220693d312c3420646f0a09200909096c6f63616c206f3d72726e64282e3035290a09200909096c6f63616c206f7370643d67756e2e7370642a28726e64282e32292b2e39290a092009090967756e3a73686f6f7428782c792c6469722b6f2c206f737064290a09200909656e640a0909656e640a09292c0a09200a09206e756c6c203d206d616b655f67756e28226e756c6c2c2035372c20302c35372c20302c312c202031")
    (hex 17664 "2c2020312c203235302c2033322c30222c0a092066756e6374696f6e2829202d2d6f7074693a2072656d6f766520617267730a0920656e64292c0a09200a09206d616368696e6567756e6d656368616e74203d206d616b655f67756e28226d616368696e6567756e6d656368616e742c2036362c20352c202e37352c2e30352c322c20312c20312c3235302c2033322c2030222c0a090973686f6f74310a09292c0a090a096578706c6f73696f6e203d206d616b655f67756e28226578706c6f73696f6e2c2035372c20302c20322c2020302c352020202c312c2020302c20312c2033322c2030222c0a090966756e6374696f6e2867756e2c782c792c646972")
    (hex 17920 "290a0a090909666f7220693d312c313220646f0a092009096c6f63616c206f3d692f31320a0920090967756e3a73686f6f7428782c792c6469722b6f290a0a092009656e640a09656e640a0a09292c0a090a09626f73735f74617267657467756e203d200a096d616b655f67756e2822626f7373207461726765742067756e2c2036352c20362c20312e322c2e30352c322c20312c2020312c203235302c2034372c2030222c0a090973686f6f74310a09292c0a090a09626f73735f33363067756e203d200a096d616b655f67756e2822626f7373203336302067756e2c2036352c20312c20312c2020302c3220202c312c2020312c093235302c2020202034")
    (hex 18176 "372c2030222c0a090966756e6374696f6e2867756e2c782c792c646972290a09090967756e2e6469722b3d2e3137363636360a09090967756e3a73686f6f7428782c792c67756e2e646972290a0909656e640a09292c0a090a09626f73735f656e656d7967756e203d200a096d616b655f67756e2822626f73735f656e656d7967756e2c2036352c203135302c20312c20312c322020202c312c2020312c203235302c2033332c2030222c0a090966756e6374696f6e2867756e2c782c792c646972290a090909736678283333290a09090967756e2e74696d6572203d2067756e2e636f6f6c646f776e0a090909696628726e642832293c312972657475726e")
    (hex 18432 "20737061776e5f656e656d7928782c792c656e656d792e6865646765686f67290a090909737061776e5f656e656d7928782c792c656e656d792e6865646765686f6762756666290a0909656e640a09292c0a7d0a092d2d7461626c65206f66206e756d6265722d696e64657865642067756e730a096967756e733d7b7d0a09666f72206b2c7620696e2070616972732867756e7329646f0a09096966286e6f7420762e69735f656e656d7929616464286967756e732c76290a09656e640a656e640a0a6b616b203d206d616b655f67756e28226b616b2c2035372c2032302c322e312c2e3030352c33202c20302c20302c20302c20202020202033362c203122")
    (hex 18688 "2c0a0973686f6f74310a290a0a0a66756e6374696f6e20726e645f67756e28290a092d2d746f646f3a2022706f7765722220706172616d0a092d2d6c6174657220776561706f6e732073686f756c6420626520200a092d2d6d6f726520706f77657266756c0a0972657475726e20726e64286967756e73290a656e640a0a66756e6374696f6e20737061776e5f62756c6c657428782c792c6469722c7370642c722c7370722c646d672c69735f656e656d792c6c69667370612c70616c65747465290a096c6f63616c2064783d636f7328646972292a7370640a096c6f63616c2064793d73696e28646972292a7370640a09616464286163746f72732c7b0a09")
    (hex 18944 "09783d782c2020793d792c0a090964783d64782c64793d64792c0a0909723d342c0a0909646d673d646d672c0a09097370643d7370642c0a09097370723d7370722c0a090969735f656e656d793d69735f656e656d792c0a090964657374726f795f666c61673d66616c73652c0a09096469723d6469722c0a09090a09097570646174653d7570646174655f62756c6c65742c0a0909647261773d647261775f62756c6c65742c0a09096c69667370613d6c69667370612c0a0a090970616c657474653d70616c657474652c0a097d290a656e640a0a66756e6374696f6e207570646174655f62756c6c65742862290a206966206e6f7428622e6c6966737061")
    (hex 19200 "3d3d206e696c297468656e0a2020622e6c69667370612d3d310a202069662028622e6c69667370613d3d20302920622e64657374726f795f666c6167203d20747275650a20656e640a09622e78202b3d20622e64780a09622e79202b3d20622e64790a090a096c6f63616c2062782c6279203d20622e782c622e79200a0a0964656275673d22220a09696620622e69735f656e656d79207468656e0a09090a09096c6f63616c207832203d20702e782b702e68782b702e68770a09096c6f63616c207932203d20702e792b702e68782b702e6877200a0909696620746f75636865735f726563742862782c62792c0a0909702e782b702e68782c20702e792b70")
    (hex 19456 "2e68792c0a090978322c793229207468656e0a0909090a090909696620702e696672616d6573203d3d2030207468656e0a09090909702e6c6966652d3d622e646d67200a09090909702e696672616d6573203d2033300a09090909736678283335290a090909656e640a0909096966287368616b653c3d34297368616b65202b3d20340a0909096b6e6f636b6261636b5f706c6179657228702c62290a0909096d616b655f7074632862782c62792c726e642834292b362c372c2e38290a090909622e64657374726f795f666c6167203d20747275650a0909090a0909656e640a09656e640a09090a096966206e6f7428622e69735f656e656d7929206f7220")
    (hex 19712 "622e737072203d3d203537207468656e0a09090a0909666f72206520696e20616c6c28656e656d69657329646f0a0909206966206c6f61646564286529207468656e0a0909096c6f63616c207832203d20652e782b652e68782b652e68770a0909096c6f63616c207932203d20652e792b652e68782b652e6877200a0909090a090909696620746f75636865735f726563742862782c62792c0a090909652e782b652e68782c652e792b652e68792c0a09090978322c793229207468656e0a090909090a09090909736678283436290a09090909652e6c696665202d3d20622e646d670a09090909696620652e6c6966653c3d30207468656e0a09090909092d")
    (hex 19968 "2d6b696c6c20656e656d790a090909090973746174732e6b696c6c732b3d312064656c28656e656d6965732c65290a0909090909737061776e5f6c6f6f7428652e782c652e79290a0909090909696620652e73707220213d20313039207468656e0a090909090962757273745f70746328652e782b342c652e792b342c382c312c312c31290a09090909090a09090909092d2d626f73732064656174680a0909090909696620652e7370723d3d31207468656e0a0909090909097368616b65202b3d2031300a090909090909626f73735f706f73203d207b652e782c652e792c652e666c69707d0a0909090909096d656e75203d2022626f7373646561746822")
    (hex 20224 "0a0909090909656e640a09090909090a0909090909656c7365202d2d616e696d6174696f6e206578706c6f73696f6e0a0909090909096b696c6c626172656c6c652865290a0909090909656e640a09090909656e640a0909090962756c6c6574735f6869742b3d310a090909090a090909096b6e6f636b6261636b5f656e656d7928652c62290a090909090a09090909652e74696d6572203d20350a090909096d616b655f7074632862782c62792c726e642834292b362c372c2e38290a09090909622e64657374726f795f666c6167203d20747275650a0909090972657475726e0a090909656e640a0909656e640a0909656e640a09656e640a090a092d2d")
    (hex 20480 "64657374726f79206f6e20636f6c6c6973696f6e0a096966202869735f736f6c69642862782c6279290a09616e64206e6f7420636865636b5f666c6167280a09202020206e6f7462756c6c6574736f6c69642c62782c62792929200a096f722062782b31313c63616d78200a096f722062783e63616d782b313339200a096f722062793c2d38206f722062793e3133320a097468656e0a09090a0909696620636865636b5f666c616728627265616b61626c652c62782c627929207468656e0a0909092d2d736678283437290a090909696620636865636b5f666c6167286c6f6f7461626c652c62782c6279297468656e0a09090909627265616b5f63726174")
    (hex 20736 "652862782c6279290a090909656e640a0909096d7365742862785c382c62795c382c3339290a0909096164642872616e646f6d2c7b0a09090920783d2862785c38292a382b342c0a09090920793d2862795c38292a382b342c0a090909207370723d726e647b35352c32322c33397d2c0a09090920663d726e647b747275652c66616c73657d2c0a09090920723d726e647b747275652c66616c73657d0a0909097d290a0909656e640a09096d616b655f7074632862782c62792c726e642834292b362c372c2e38290a0909090a0909622e64657374726f795f666c6167203d20747275650a09656e640a656e640a0a66756e6374696f6e20647261775f6275")
    (hex 20992 "6c6c65742862290a0970616c2873706c697428622e70616c6574746529290a0973707228622e7370722c20622e782d342c20622e792d342c312c312c20702e666c6970290a0970616c28290a656e640a0a66756e6374696f6e20647261775f72616e646f6d28290a666f72206920696e20616c6c2872616e646f6d29646f0a092073707228692e7370722c20692e782d342c20692e792d342c312c312c692e662c692e72290a09656e640a656e640a0a66756e6374696f6e206b696c6c626172656c6c652865290a20616e696d6578706c6f2865290a09652e67756e3a6669726528652e782b342c652e792b342c652e61290a0964656c28656e656d6965732c")
    (hex 21248 "65290a656e640a0a66756e6374696f6e20616e696d6578706c6f2865290a666f7220693d312c313520646f0a09096d616b655f707463280a0909090909652e78202b2072726e64283134292c0a0909090909652e79202b2072726e64283134292c0a090909382b726e642838292c726e647b392c31307d290a09656e640a736678283337290a7368616b65202b3d20370a656e640a0a2d2d2d2d2d2d2d2d0a0a2d2d5b5b0a66756e6374696f6e20737061776e5f62756c6c657428782c792c747970655f62756c6c65742c73706565642c74696d65725f62756c6c6574312c7370726974652c6e625f62756c6c65742c6563617274656d656e74290a09696620")
    (hex 21504 "74696d65725f62756c6c6574203d3d2030207468656e0a09096c6f63616c207879203d206765745f7472616a28782c792c6d6f7573655f782c6d6f7573655f79290a09096c6f63616c207472616a5f78203d2078792e782a73706565640a09096c6f63616c207472616a5f79203d2078792e792a73706565640a09096c6f63616c20616e676c65203d2078792e616e676c650a090974696d65725f62756c6c6574203d2074696d65725f62756c6c6574310a09090a0909696620747970655f62756c6c6574203d3d2031207468656e0a0909096e76656c656d656e74203d207b0a0909092020783d782c793d792c0a0909092020747970655f62756c6c65743d")
    (hex 21760 "747970655f62756c6c65742c0a09090920207472616a5f783d7472616a5f782c0a09090920207472616a5f793d7472616a5f792c0a09090920207370726974653d7370726974650a0909097d0a090909726166616c652831302c6e76656c656d656e74290a0909656e640a09200a0920696620747970655f62756c6c6574203d3d2032207468656e0a092020666f7220693d302c6e625f62756c6c657420646f0a092020206966206e625f62756c6c6574203d3d2030207468656e0a09202020206164642862756c6c65742c7b0a09202020202020783d782c793d792c0a09202020202020747970655f62756c6c65743d747970655f62756c6c65742c0a0920")
    (hex 22016 "20202020207472616a5f783d7472616a5f782c0a092020202020207472616a5f793d7472616a5f792c0a092020202020207370726974653d7370726974650a09202020207d290a09090909656c7365200a09090909096164642862756c6c65742c7b0a09090909092020783d782c793d792c0a09090909092020747970655f62756c6c65743d747970655f62756c6c65742c0a090909090920207472616a5f783d636f732828616e676c652d2828312f6563617274656d656e74292f32292b28692f6e625f62756c6c6574292f6563617274656d656e7429292a73706565642c0a090909090920207472616a5f793d73696e2828616e676c652d2828312f6563")
    (hex 22272 "617274656d656e74292f32292b28692f6e625f62756c6c6574292f6563617274656d656e7429292a73706565642c0a090909090920207370726974653d7370726974650a09090909097d290a09202020656e640a092020656e640a0920656e640a20656e640a656e640a0a2d2d202d28692f32292b692f6e625f62756c6c65740a66756e6374696f6e207570646174655f62756c6c657428290a206966202874696d65725f62756c6c65743e302974696d65725f62756c6c65742d3d310a09666f72206920696e20616c6c2862756c6c65742920646f0a090969662069735f736f6c696428692e782b28692e7472616a5f782a312e35292b342c692e792b342b")
    (hex 22528 "28692e7472616a5f792a312e352929207468656e0a09092064656c2862756c6c65742c69290a0920656e640a0909692e78202b3d20692e7472616a5f780a0909692e79202b3d20692e7472616a5f790a09656e640a656e640a0a66756e6374696f6e20647261775f62756c6c657428290a09666f72206920696e20616c6c2862756c6c65742920646f0a090973707228692e7370726974652c692e782c692e79290a09656e640a656e640a0a66756e6374696f6e20726166616c65286e622c62756c6c6574290a2061646428726166616c656c732c7b6e623d6e622c62756c6c65743d62756c6c65747d290a656e640a0a66756e6374696f6e20757064617465")
    (hex 22784 "726166616c652829090a09666f72206920696e20616c6c28726166616c656c732920646f0a202069662028692e6e623c31292064656c28726166616c656c732c69290a20206164642862756c6c65742c692e62756c6c6574290a2020692e6e62202d3d310a09656e640a656e640a2d2d5d5d0a2d2d3e380a2d2d6d6f7573650a66756e6374696f6e206d6f7573655f785f7928290a09706f6b65283078356632642c2031290a096d783d73746174283332292b666c722863616d78290a096d793d73746174283333290a096c6f63616c2073203d2073746174283334290a096c6d623d732631203e20300a09726d623d732632203e20300a656e640a0a0a0a0a")
    (hex 23040 "2d2d5b5b66756e6374696f6e206765745f7472616a28785f736174722c795f73746172742c785f656e642c795f656e64290a09616e676c653d6174616e3228785f656e642d785f736174722d342c200a0920795f656e642d795f73746172742d34290a0972657475726e207b783d636f7328616e676c65292c0a0920793d73696e28616e676c65292c616e676c653d616e676c657d0a656e645d5d0a0a66756e6374696f6e20636865636b5f666c616728666c61672c782c79290a0972657475726e2066676574286d6765742828785c38292c28795c3829292c666c6167290a656e640a0a2d2d3e380a2d2d636f6c6c6973696f6e0a66756e6374696f6e2069")
    (hex 23296 "735f736f6c696428782c79290a09696628783c302972657475726e2074727565200a0972657475726e20636865636b5f666c616728302c782c79290a656e640a0a66756e6374696f6e20746f75636865735f7265637428782c792c78312c79312c78322c7932290a0972657475726e207831203c3d20780a09202020616e64207832203e3d20780a09202020616e64207931203c3d20790a09202020616e64207932203e3d20790a656e640a2d2d5b5b0a66756e6374696f6e20636972635f636f6c6c28612c62290a092d2d68747470733a2f2f7777772e6c6578616c6f66666c652e636f6d2f6262732f3f7469643d32383939390a092d2d623a2062756c6c")
    (hex 23552 "65740a096c6f63616c2064783d612e782b34202d20622e780a096c6f63616c2064793d612e792b34202d20622e790a096c6f63616c2064203d206d61782864782c6479290a096478202f3d20640a096479202f3d20640a096c6f63616c207372203d2028612e722b622e72292f640a090a0972657475726e2064782a64782b64792a6479203c2073722a7372200a656e640a2d2d5d5d0a0a66756e6374696f6e20726563745f6f7665726c61702861312c61322c62312c6232290a092d2d5b5b72657475726e206e6f74202861312e783e62322e780a092020202020202020206f722061312e793e62322e79200a092020202020202020206f722061322e783c")
    (hex 23808 "62312e780a092020202020202020206f722061322e793c62312e79292d2d5d5d0a090a0972657475726e2061312e783c62322e780a09202020616e642061312e793c62322e79200a09202020616e642061322e783e62312e780a09202020616e642061322e793e62312e792d2d5d5d0a656e640a0a66756e6374696f6e20636f6c6c6973696f6e28782c792c772c682c666c6167290a0972657475726e200a0920202069735f736f6c696428782c202079290a096f722069735f736f6c696428782b772c79290a096f722069735f736f6c696428782c2020792b68290a096f722069735f736f6c696428782b772c792b6829200a656e640a0a66756e6374696f")
    (hex 24064 "6e20636f6c6c696465286f2c626f756e636531290a096c6f63616c20782c79203d206f2e782c6f2e790a096c6f63616c2064782c6479203d206f2e64782c6f2e64790a096c6f63616c20772c68203d206f2e62772c6f2e62680a096c6f63616c206f782c6f79203d20782b6f2e62782c792b6f2e62790a096c6f63616c20626f756e6365203d20626f756e6365310a090a092d2d636f6c6c6973696f6e730a096c6f63616c2077652c6865203d20772d312c20682d310a096c6f63616c20636f6c6c5f78203d20636f6c6c6973696f6e28200a096f782b64782c206f792c2020202077652c206865290a096c6f63616c20636f6c6c5f79203d20636f6c6c6973")
    (hex 24320 "696f6e280a096f782c202020206f792b64792c2077652c206865290a096c6f63616c20636f6c6c5f7879203d20636f6c6c6973696f6e280a096f782b64782c206f792b64792c2077652c206865290a090a09696620636f6c6c5f78207468656e0a09096f2e6478202a3d202d626f756e63650a09656e640a090a09696620636f6c6c5f79207468656e0a09096f2e6479202a3d202d626f756e63650a09656e640a090a09696620636f6c6c5f787920616e64200a096e6f7420636f6c6c5f7820616e64206e6f7420636f6c6c5f79207468656e0a09092d2d70726576656e7420737475636b20696e20636f726e657273200a09096f2e6478202a3d202d626f75")
    (hex 24576 "6e63650a09096f2e6479202a3d202d626f756e63650a09656e640a656e640a2d2d3e380a2d2d6d6170200a74657374203d20300a7761676f6e5f6e203d20300a0a66756e6374696f6e2067656e5f747261696e28290a092d2d67656e2074616c6265206f6620616c6c207761676f6e206e756d730a096e756d73203d207b7d0a09666f7220693d31302c323920646f0a0909616464286e756d732c69290a09656e640a090a092d2d67656e20747261696e0a09747261696e203d207b5b305d3d397d0a090a09666f7220693d302c746c20646f0a09096c6f63616c2077203d20692a776c0a0909666f72206a3d302c3220646f0a0909090a0909096c6f63616c")
    (hex 24832 "206e203d2031302b666c7228726e6428323129290a090909696628236e756d733e30296e3d6e756d735b666c7228726e6428236e756d7329292b315d0a090909747261696e5b772b6a5d3d6e0a09090964656c286e756d732c6e290a0909090a0909656e640a0909747261696e5b772b335d203d20380a09656e640a090a09747261696e5b305d3d390a090a09666f72206a3d302c3220646f0a0909747261696e5b746c2a342b6a5d3d33300a09656e640a09747261696e5b28746c2b31292a34202d20315d3d33310a656e640a0a66756e6374696f6e20636c6f6e655f726f6f6d28612c62290a096c6f63616c206178203d2028612538292a31360a096c6f")
    (hex 25088 "63616c206179203d2028615c38292a31360a09726f6f6d5f616c6c3d207b7d0a09666f72206a203d20302c313520646f0a0909666f722069203d20302c313520646f0a0909096c6f63616c20743d6d6765742861782b692c61792b6a290a0909096d73657428622a31362b692c6a2c74290a0909656e640a09656e640a656e640a0a66756e6374696f6e207570646174655f646f6f7228290a096c6f63616c20776c203d20776c0a092d2d756e6c6f636b206e657874207761676f6e0a0969662023656e656d696573203c3d203020616e64200a096e6f7420656e656d696573636c6561726564207468656e0a09090a0909736678283337290a090973667828")
    (hex 25344 "3432290a09090a09096c6f63616c20783d28776c2d31292a31360a09096c6f63616c20673d726e645f67756e28290a09090a09096d616b655f64726f7028782a382b36302c35362c672e7370722c2267756e222c0a0909636f7079286729290a0909656e656d696573636c65617265643d747275650a09090a0909666f7220693d312c3520646f0a0909096d616b655f707463280a0909092020782a38202b2072726e642838292c0a0909092020353620202b2072726e642838292c0a090909382b726e642838292c726e647b392c31307d290a0909656e640a09090a09096966207761676f6e5f6e203c20746c207468656e0a0909096d73657428782c362c")
    (hex 25600 "3430290a0909096d73657428782c372c3339290a0909656c73650a090909696e69745f626f73735f726f6f6d2878290a0909656e640a09090a09097368616b65202b3d20350a09090a09656e64200a656e640a0a66756e6374696f6e20696e69745f626f73735f726f6f6d2878290a096d73657428782c342c3430290a09666f7220693d352c3920646f0a09096d73657428782c692c3339290a09656e640a096d73657428782c31302c3132290a656e640a0a66756e6374696f6e20626567696e5f626f737328290a096c6f63616c2078203d2028776c2d31292a31360a09737061776e5f656e656d7928782a382b382a31322c0a0935362c656e656d792e62")
    (hex 25856 "6f7373290a090a096d73657428782c692c36290a09666f7220693d352c3920646f0a09096d73657428782c692c36290a090962757273745f70746328782a382c692a382c3130290a09656e640a096d73657428782c692c36290a656e640a0a66756e6374696f6e207570646174655f726f6f6d28290a09666f7220693d302c3320646f0a09096c6f63616c20773d7761676f6e5f6e2a776c202b20690a09090a09092d2d7072696e74682822747261696e5b222e2e746f7374722877292e2e225d3a222e2e746f73747228747261696e5b775d29290a0909636c6f6e655f726f6f6d28747261696e5b775d2c69290a09656e640a097072696e746828222d2d2d")
    (hex 26112 "22290a656e640a0a66756e6374696f6e20647261775f6d617028290a092d2d2077616c6c2070616c657474650a2d2d0969662870616c5f6e3e23747261696e70616c292070616c5f6e3d310a2d2d0970616c28382c747261696e70616c5b70616c5f6e5d5b315d290a2d2d0970616c2831342c747261696e70616c5b70616c5f6e5d5b325d290a0a202d2d207a65703a0a2070616c5f6e3d6d696e28372c70616c5f6e290a2070616c28382c747261696e70616c5b70616c5f6e2a322d315d290a2070616c2831342c747261696e70616c5b70616c5f6e2a325d290a090a09647261775f67686f73745f636f6e6e6563746f7228290a096d617028290a096472")
    (hex 26368 "61775f72616e646f6d28290a090a0970616c7428290a0970616c28290a656e640a0a66756e6374696f6e20627265616b5f637261746528782c79290a092d2d737061776e5f6c6f6f7428785c382a382c795c382a38290a09737061776e5f6c6f6f742878267e372c79267e3729202d2d207a65700a090a656e640a0a0a0a66756e6374696f6e20737769636874696c6528782c79290a206c6f63616c2074203d206d6765742828785c38292c28795c3829290a206d7365742828785c38292c28795c38292c742b31290a656e640a0a66756e6374696f6e20706172636f75726d617028290a0a206c6f63616c2078313d300a206966287761676f6e5f6e3d3d30")
    (hex 26624 "2978313d31360a2009666f7220783d78312c31362a28776c2d312920646f0a202009666f7220793d322c313220646f0a20202009696620783e33206f7220702e792d313030303e792a38206f7220702e792b313030303c792a38207468656e0a20202020096966206d67657428782c79293d3d313039207468656e0a2020200920206d73657428782c792c3339290a202020092020696620726e642834293e33207468656e0a202020092020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e6578706c6f736976655f62617272656c290a202020092020656e640a2020202009656c736569662066676574286d67657428782c7929")
    (hex 26880 "2c322920616e64206365696c28726e64286d617828332c64696666692d287761676f6e5f6e2a312e3635292929293d3d31207468656e0a202020202020736170776e726e64656e656d7928782c79290a2020202009656e640a20202009656e640a202009656e640a2020656e640a20656e640a0a0a66756e6374696f6e20736170776e726e64656e656d7928782c79290a092d2d737061776e206578706c6f736976655f62617272656c200a2020202020206966206365696c28726e6428323529293d3d3130207468656e0a202020202020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e6578706c6f736976655f62617272656c")
    (hex 27136 "290a20202020202d2d737061776e206a75676765726e6175740a2020202020656c73656966206365696c28726e6428333229293e33312d287761676f6e5f6e2a302e372920616e64207761676f6e5f6e3e31207468656e0a202020202020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e6a75676765726e617574290a20202020200a20202020202d2d737061776e207761726d0a2020202020656c73656966206365696c28726e6428333029293e32382e352d287761676f6e5f6e2a302e352920616e64207761676f6e5f6e3e30207468656e0a202020202020666f7220693d302c6365696c28726e64287761676f6e5f6e2f32")
    (hex 27392 "29292b3820646f0a202020202020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e7761726d290a202020202020656e640a20202020200a20202020202d2d737061776e20746f7572656c6c65200a0a202020202020656c73656966206365696c28726e6428333029293e33322e352d287761676f6e5f6e2a312920616e64207761676f6e5f6e3e32207468656e0a0a202020202020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e746f7572656c6c65290a20202020202d2d737061776e206865646765686f67200a2020202020656c7365200a2020202020206966206365696c28726e642832332929")
    (hex 27648 "3e32372d287761676f6e5f6e2a322e3529207468656e0a20202020202020737061776e5f656e656d792878202a20382c79202a20382c656e656d792e6865646765686f6762756666290a202020202020656c736520737061776e5f656e656d792878202a20382c79202a20382c656e656d792e6865646765686f67290a2020202020200a2020202020656e640a2020202020656e640a656e640a2d2d3e380a2d2d656e656d6965730a66756e6374696f6e206d616b655f656e656d7928782c792c7370722c0a7370642c6c6966652c6167726f2c63686173652c73656572616e67652c0a67756e74290a0972657475726e207b0a0909783d782c20793d792c0a")
    (hex 27904 "0909616e676c653d302c0a09090a090970616e676c653d302c0a09090a090964783d302c64793d302c0a09097370643d7370642c0a09096167726f3d6167726f2c0a09090a090962783d312c62793d312c0a090962773d362c62683d362c0a09090a090968783d302c68793d302c0a090968773d382c0a09090a090963686173653d63686173652c0a090973656572616e67653d73656572616e67652c0a09097370723d7370722c0a09096c6966653d6c6966652c0a09090a090967756e3d67756e742c0a090963643d33302c0a090974696d6572203d20302c0a0909613d302c0a097d0a656e640a0a66756e6374696f6e20696e69745f656e656d69657328")
    (hex 28160 "290a09656e656d793d207b0a090a096865646765686f673d6d616b655f656e656d79280a2d2d782c792c7370726974652c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c3130382020202c31202020202c352020202c372e37352020202c0a2d2d63686173652c73656572616e67650a092066616c73652c312c0a092067756e732e67756e736c696d65292c0a09200a096865646765686f67627566663d6d616b655f656e656d79280a2d2d782c792c7370726974652c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c39322020202c31202020202c31302020202c372e37352020202c0a2d2d63")
    (hex 28416 "686173652c73656572616e67650a092066616c73652c312c0a092067756e732e67756e736c696d6562756666292c0a09200a09200a20206a75676765726e6175743d6d616b655f656e656d79280a2d2d782c792c7370726974652c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c3934202020202c312e3520202c333020202c332020202c20200a2d2d63686173652c73656572616e67650a2020747275652c382c200a092067756e732e73686f7467756e6d656368616e74292c0a09200a09207761726d3d6d616b655f656e656d79280a2d2d782c792c7370726974652c73706565642c6c6966652c73686f6f7472616e6765")
    (hex 28672 "2c20200a0920782c792c313236202020202c3120202c3120202c302020202c20200a2d2d63686173652c73656572616e67650a2020747275652c362e352c200a092067756e732e6e756c6c292c0a09200a0920746f7572656c6c653d6d616b655f656e656d79280a2d2d782c792c7370726974652c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c3132352020202c30202020202c31352020202c362e352020202c0a2d2d63686173652c73656572616e67650a092066616c73652c312c0a092067756e732e6d616368696e6567756e6d656368616e74292c0a09200a09206578706c6f736976655f62617272656c3d6d616b65")
    (hex 28928 "5f656e656d79280a2d2d782c792c7370722c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c31303920202c30202020202c302e31202c302c0a2d2d63686173652c73656572616e67650a092066616c73652c302c0a092067756e732e6578706c6f73696f6e292c0a09200a09626f73733d6d616b655f656e656d79280a2d2d782c792c7370722c73706565642c6c6966652c73686f6f7472616e67652c20200a0920782c792c3120202c33202020202c333030202c33322c0a2d2d63686173652c73656572616e67650a0920747275652c33322c0a0a092067756e732e626f73735f33363067756e292c0a7d0a0a6c6f63616c20")
    (hex 29184 "623d656e656d792e626f73730a622e6277203d2031350a622e6268203d2031350a622e6877203d2031360a622e67756e73203d207b67756e732e626f73735f74617267657467756e2c0a67756e732e626f73735f33363067756e2c0a67756e732e626f73735f656e656d7967756e7d0a622e7068617365203d20300a622e706861736574696d6572203d20300a622e70617573653d300a0a656e640a0a66756e6374696f6e20737061776e5f656e656d7928782c792c6e616d65290a096c6f63616c20613d636f7079286e616d65290a09612e78203d20780a09612e79203d20790a09612e67756e203d20636f707928612e67756e290a096c6f63616c207220")
    (hex 29440 "3d20726e64283630290a09696628612e7370723d3d312972203d20300a0969662028612e73707220213d2031323529612e67756e2e636f6f6c646f776e202b3d20720a090a2069662028612e737072203d3d2031323629612e737064203d20302e382b726e6428302e34290a20696620612e783c313735207468656e0a2020612e67756e2e74696d6572202b3d2039300a2020612e74696d6572203d2039300a20656e640a200a0961646428656e656d6965732c61290a656e640a0a66756e6374696f6e207570646174655f656e656d792865290a09666f72206920696e20616c6c28656e656d6965732920646f0a09096966206c6f61646564286929207468")
    (hex 29696 "656e0a0909096d6f7576726e64203d20747275650a0909090a090909692e67756e2e74696d6572203d206d617828692e67756e2e74696d65722d312d2d2f23656e656d6965730a0909092c30290a0909090a090909696620692e67756e2e74696d65723c3d3020616e64200a0909092863616e73686f6f7428692c7029206f7220692e7370723d3d31297468656e0a090909090a09090909692e67756e3a6669726528692e782b342c692e792b342c692e61290a090909656e640a0909096966206d6f7576726e64207468656e0a090909096368616e6765646972656374696f6e2869290a090909656e640a090909636f6c6c69646528692c302e31290a0909")
    (hex 29952 "090a090909692e70616e676c653d6174616e3228702e782d692e782c702e792d692e79290a0909096966206e6f742028692e7370723d3d2031303929207468656e0a09090909692e666c69703d69736c65667428692e70616e676c65290a090909656e640a0909090a090909696628692e7370723d3d3129207570646174655f626f73732869290a0909090a090909692e78202b3d20692e64780a090909692e79202b3d20692e64790a0909656e640a09656e640a656e640a0a66756e6374696f6e20647261775f656e656d792865290a096c6f63616c2077203d20310a09696628652e7370723d3d3129773d320a090a096c6f63616c20783d666c7228652e")
    (hex 30208 "78292b0a09636f7328652e70616e676c65292a362a770a096c6f63616c20793d666c7228652e79292b0a0973696e28652e70616e676c65292a332a770a090a0973707228652e67756e2e7370722c782c792c312c312c20652e666c6970290a090a0973707228652e7370722c652e782c652e792c772c772c20652e666c6970290a090a092d2d626f7373206865616c7468206261720a09696620652e7370723d3d31207468656e0a09097265637466696c6c2863616d782b312c3132302c0a090963616d782b3132362c3132362c34290a09096c6f63616c206c3d3132362a28652e6c6966652f333030290a09097265637466696c6c2863616d782b322c3132")
    (hex 30464 "312c63616d782b322b6c2c0a09093132352c39290a09090a09096c6f63616c20733d22f09f90b1222e2e6365696c28652e6c696665292e2e222f222e2e22333030220a09097072696e7428732c2063616d782b332c3132312c37290a09656e640a090a092d2d7072696e7428652e6c6966652c20652e782c652e792d382c37290a092d2d6369726328652e782b342c652e792b342c652e722c3132290a092d2d7072696e7428652e67756e2e74696d65722c652e782c652e79290a092d2d7072696e742861627328652e6479292b61627328652e6478292c652e782c652e792b36290a656e640a0a66756e6374696f6e207570646174655f626f73732869290a")
    (hex 30720 "09692e706861736574696d6572202d3d20310a09692e7061757365202d3d20310a090a09696620692e706861736574696d65723c30207468656e0a0909692e706861736574696d65723d3630302b726e6428363030290a0909692e70686173652b3d310a0909692e7061757365203d203230300a09656e640a09696628692e70686173653e3329692e70686173653d310a090a09692e67756e3d692e67756e735b692e70686173655d0a09696628692e70617573653e302920692e67756e203d2067756e732e6e756c6c0a656e640a0a66756e6374696f6e206368616e6765646972656374696f6e2869290a09692e74696d65722d3d310a09696620692e7469")
    (hex 30976 "6d6572203c2031207468656e0a0920692e616e676c65202b3d2072726e6428302e3235290a0920692e74696d65723d692e63640a0920692e64783d636f7328692e616e676c65292f382a692e737064200a0920692e64793d73696e28692e616e676c65292f382a692e7370640a09656e640a656e640a0a66756e6374696f6e2063616e73686f6f7428652c706c290a096c6f63616c20616e676c65203d206174616e3228706c2e782d652e782c0a09706c2e792d652e79290a09652e613d616e676c650a096c6f63616c2078203d20636f7328616e676c65290a096c6f63616c2079203d2073696e28616e676c6529200a096c6f63616c2064697374203d2064")
    (hex 31232 "69737428652c706c290a090a09696620286162732864697374293c652e6167726f20616e642061627328706c2e782d652e78293c31323829206f7220653d3d70207468656e0a090972657475726e2063616e73656528652c616e676c652c782c792c64697374290a09656c73656966206162732864697374293c652e73656572616e676520616e64206162732864697374293e652e6167726f20616e6420652e636861736520616e642063616e73656528652c616e676c652c782c792c6469737429207468656e0a20206f3d20652e64782b652e64790a202020652e64783d782a28652e7370642a32292f6d617828646973742c34290a202020652e64793d79")
    (hex 31488 "2a28652e7370642a32292f6d617828646973742c34290a2020200a202020206d6f7576726e64203d2066616c73650a2020200a20200a20656e64090a656e640a0a66756e6374696f6e206469737428652c70290a0972657475726e20737172742861627328702e792d652e79295e322b61627328702e782d652e78295e32292f380a656e640a200a66756e6374696f6e2063616e73656528652c616e676c652c782c792c646973742909200a20666f722069203d312c6469737420646f0a0961646428636865636b65722c7b783d652e782b782a692a382c793d652e792b792a692a387d2920200a092069662069735f736f6c696428636865636b65725b2363")
    (hex 31744 "6865636b65725d2e782b342c636865636b65725b23636865636b65725d2e792b3429207468656e0a09200964656c636865636b657228290a0920096966202865213d702920652e67756e2e74696d6572203d20652e67756e2e636f6f6c646f776e2f320a092072657475726e2066616c7365200a0920656e640a09656e640a0964656c636865636b65722829200a0972657475726e2074727565200a656e640a0a0a66756e6374696f6e2064656c636865636b657228290a09636865636b6572203d207b7d0a656e640a0a66756e6374696f6e206c6f616465642869290a0972657475726e206162732863616d782b36342d692e78293c37312d2d37310a656e")
    (hex 32000 "640a2d2d3e380a2d2d7061727469636c657320262062670a66756e6374696f6e20696e69745f70746328290a097061727469636c65733d7b7d0a096772617373203d207b7d0a09666f7220693d302c323020646f200a096164642867726173732c7b783d666c7228726e6428313629292a382c20793d666c7228726e6428313629292a382c207370723d35367d290a09656e640a09666f7220693d302c3520646f200a096164642867726173732c7b783d666c7228726e6428313629292a382c20793d726e647b302c3131327d2c207370723d35367d290a09656e640a09666f7220693d302c3320646f0a09666f7220763d342c313420646f0a096164642867")
    (hex 32256 "726173732c7b783d33322a692c793d762a382c7370723d32347d290a09656e640a09656e640a097765656c666c6970203d20747275650a097765656c6672616d65203d20350a097765656c636f756e74203d207765656c6672616d650a656e640a0a66756e6374696f6e206d616b655f70746328782c792c722c636f6c2c667269632c64782c64792c747874290a09667269633d66726963206f7220726e64282e31292b2e38350a0964783d6478206f7220300a0964793d6479206f7220300a09616464287061727469636c65732c207b0a0909783d782c2020793d792c0a090964783d64782c64793d64792c0a0909667269633d667269632c0a09090a0909")
    (hex 32512 "7478743d7478742c0a09090a0909723d722c20636f6c3d636f6c2c0a090964657374726f793d66616c73652c0a097d290a656e640a0a66756e6374696f6e207570646174655f70746328707463290a097074632e78202b3d207074632e64780a097074632e79202b3d207074632e64790a090a097074632e6478202a3d207074632e667269630a097074632e6479202a3d207074632e667269630a090a097074632e72202a3d207074632e667269630a090a096966287074632e723c3d31297074632e64657374726f793d747275650a656e640a0a66756e6374696f6e20647261775f70746328707463290a092d2d6b696e646120626f646765792062757420")
    (hex 32768 "77686174657665720a096966207074632e7478743d3d6e696c207468656e0a09096369726366696c6c287074632e782c7074632e792c7074632e722c7074632e636f6c290a09656c73650a09097072696e74287074632e7478742c7074632e782c7074632e792c7074632e636f6c290a09656e640a656e640a0a66756e6374696f6e2062757273745f70746328782c792c636f6c290a09666f7220693d312c3520646f0a09096d616b655f707463280a0909202020782b72726e642838292c0a0909202020792b72726e642838292c0a0909202020726e642835292b352c636f6c2c0a0909202020302e392b726e6428302e303729290a09656e64200a656e64")
    (hex 33024 "0a0a66756e6374696f6e20677261737374696c6528290a09666f72206920696e20616c6c28677261737329646f0a0920692e78203d20692e780a0909692e782d3d322e350a090969662028692e783c2d3829692e78203d203132380a09656e640a656e640a0a66756e6374696f6e2064726177677261737328290a09666f7220656c7420696e20616c6c28677261737329646f0a090973707228656c742e7370722c63616d782b656c742e782c656c742e79290a09656e640a656e640a0a66756e6374696f6e20647261775f7765656c28290a207765656c636f756e74202d3d310a20696620287765656c636f756e743c3129207765656c666c6970203d206e")
    (hex 33280 "6f74207765656c666c6970207765656c636f756e743d7765656c6672616d650a20666f72206e3d302c3520646f0a09666f7220693d302c3220646f0a09097370722834322c382b6e2a36342b692a31362c31342a382c20322c322c7765656c666c6970292d2d2c20666c69705f78202c666c69705f79290a09656e640a09656e640a656e640a0a2d2d2d2d0a0a0a2d2d3e380a2d2d6d656e75730a66756e6374696f6e20696e69745f6d656e757328290a096d656e7573203d207b7d0a096d656e75732e6d61696e203d206d616b655f6d61696e5f6d656e7528290a096d656e75732e6465617468203d206d616b655f64656174685f6d656e752866616c7365")
    (hex 33536 "290a096d656e75732e626f73736465617468203d206d616b655f626f73735f646561746828290a096d656e75732e77696e203d206d616b655f64656174685f6d656e752874727565290a656e640a0a2d2d5b5b0a66756e6374696f6e20647261775f62617228742c782c792c772c77322c632c6332290a097265637466696c6c28782c792c0a09782b772b322c792b352c6332290a096c6f63616c206c3d772a77320a097265637466696c6c28782b312c792b312c0a09782b312b6c2c792b352c63290a090a097072696e7428742c20782b312c792b312c37290a656e642d2d5d5d0a0a66756e6374696f6e206d616b655f626f73735f646561746828290a09")
    (hex 33792 "6c6f63616c206d3d7b0a0974696d65723d3430302c0a090a097570646174653d66756e6374696f6e286d290a0909666f72206520696e20616c6c28656e656d69657329646f2064656c28652c656e656d6965732920656e640a09096d75736963282d312c30290a09096966286d2e74696d65723d3d34303029736678283435292d2d736678283436290a09090a09096d2e74696d6572202d3d20330a09090a09096966206d2e74696d65723c30207468656e0a0909096d656e75203d202267616d65220a09090977696e3d747275650a0909097368616b65202b3d2034300a090909736678283438290a0909090a090909666f7220693d312c313820646f0a09")
    (hex 34048 "0909096d616b655f7074632863616d782b726e6428313238292c0a09090909726e6428313238292c35302b726e64283230292c0a09090909726e647b382c392c31307d2c2e3935290a090909090a2d2d28782c792c722c636f6c2c667269632c64782c64792c747874290a090909656e640a0909656e640a09090a09096d782c6d793d2d31302c2d31300a09656e642c0a090a09647261773d66756e6374696f6e286d290a09090a09096c6f63616c20782c79203d20626f73735f706f735b315d2b382c626f73735f706f735b325d2b380a09096c6f63616c20666c70203d20626f73735f706f735b335d0a09096c6f63616c2074203d206d2e74696d65720a")
    (hex 34304 "09096369726366696c6c28782c792c74202020202c38290a09096369726366696c6c28782c792c742a2e37352c39290a09096369726366696c6c28782c792c742a2e35202c3130290a09096369726366696c6c28782c792c742a2e32352c37290a090973707228312c782d382c792d382c322c322c666c70290a09656e640a097d0a0972657475726e206d0a656e640a2d2d2d2d2d2d0a0a66756e6374696f6e206d616b655f6d61696e5f6d656e7528290a092d2d7468697320636f646520636f756c64206265206265747465720a096c6f63616c206d203d207b0a0920207570646174653d7570646174655f6d61696e5f6d656e752c0a092020647261773d")
    (hex 34560 "647261775f6d61696e5f6d656e752c0a0920200a09202073656c3d302c0a092020646f6e653d66616c73652c0a09202075695f6f793d302c0a09202075695f64793d302c0a0920200a0920206861735f6163746976653d66616c73652c0a097d0a096d2e627574746f6e733d7b7d0a090a096c6f63616c206e616d65733d73706c697422706967656f6e2c6475636b2c73706172726f772c706172726f742c746f7563616e2c666c616d696e676f2c6561676c652c73656167756c6c2c6f7374726963682c70656e6775696e2c6a61792c636869636b656e220a096c6f63616c20783d340a096c6f63616c20793d3130350a09666f7220693d312c313220646f")
    (hex 34816 "0a0909616464286d2e627574746f6e732c7b0a090920206e3d692c0a090920207370723d692b37392c0a09092020626972643d692b3131312c0a090920200a09092020783d692a31302d362c0a09092020793d3130352c0a09092020773d392c0a09092020683d31372c0a09092020636f6c3d312c0a0909202073683d322c0a090920200a090920206e616d653d6e616d65735b695d2c0a090920206163746976653d66616c73652c0a09097d290a09656e640a090a092d2d2d2d2d2d2d0a0966756e6374696f6e206d616b655f62746e2861726773290a09096e2c73702c626972642c782c792c772c682c6e616d653d756e7061636b2873706c6974286172")
    (hex 35072 "677329290a090972657475726e207b0a090920206e3d6e2c0a090920207370723d73702c0a09092020626972643d626972642c0a090920200a09092020783d782c793d792c0a09092020773d772c683d682c0a090920200a090920206f793d302c0a09092020636f6c3d312c0a0909202073683d312c0a090920200a090920206e616d653d6e616d652c0a090920206163746976653d66616c73652c0a09097d0a09656e640a092d2d2d2d2d2d2d0a096d2e627574746f6e735b305d3d6d616b655f62746e2822302c3132342c33392c3131342c39312c392c392c72616e646f6d22290a09090a096d2e627574746f6e735b31335d3d6d616b655f62746e2822")
    (hex 35328 "31332c3131312c33392c322c322c392c392c72616e646f6d22290a090a0972657475726e206d0a656e640a0a66756e6374696f6e207570646174655f6d61696e5f6d656e75286d290a096c6f63616c2073656c656374696f6e3d313030300a090a096966206e6f74206d2e646f6e65207468656e0a09092d2d75706461746520627574746f6e730a0909666f72206b3d302c236d2e627574746f6e7320646f0a0909096c6f63616c2069203d206d2e627574746f6e735b6b5d0a0909090a0909092d2d6f6e20686f7665720a090909696620746f75636865735f72656374286d782c6d792c692e782c692e792c0a090909692e782b692e772d312c20692e792b")
    (hex 35584 "692e682d3129207468656e0a09090909692e636f6c203d20370a09090909692e6f79203d20320a090909090a090909096966286e6f7420692e6163746976652920736678283433290a090909096d2e6861735f6163746976653d747275650a090909096d2e73656c203d20692e6e0a09090909692e6163746976653d747275650a090909090a090909092d2d206f6e20636c69636b0a090909096966206c6d62207468656e200a090909090973656c656374696f6e203d20692e6e0a09090909656e640a0909090a090909656c73650a090909090a09090909692e616374697665203d2066616c73650a09090909692e636f6c203d20310a09090909692e6f79")
    (hex 35840 "203d20300a090909090a090909656e642d2d69660a0909656e642d2d666f720a09090a09092d2d627574746f6e730a0909666f72206e3d302c3120646f0a090969662862746e7028293e3029736678283433290a090969662862746e7028e2ac85efb88f2c6e29296d2e73656c202d3d20310a090969662862746e7028e29ea1efb88f2c6e29296d2e73656c202b3d20310a090969662862746e7028e2ac86efb88f2c6e29296d2e73656c3d286d2e73656c3d3d3029616e64203133206f7220300a090969662862746e7028e2ac87efb88f2c6e29296d2e73656c3d310a0909656e640a090969662862746e28e29d8e296f722062746e28f09f85beefb88f29")
    (hex 36096 "2973656c656374696f6e3d6d2e73656c0a09090a09096d2e73656c253d31340a09096c6f63616c20623d6d2e627574746f6e735b6d2e73656c5d0a0909622e616374697665203d20747275650a09096d2e6861735f6163746976653d747275650a0909622e6f792c622e636f6c203d20322c370a09090a09090a09092d2d2072756e2073656c656374696f6e0a090969662073656c656374696f6e3c3d3132207468656e0a0909096d2e646f6e65203d20747275650a0909656c736569662073656c656374696f6e3d3d3133207468656e0a090909686172646d6f646574696d65722b3d310a0909656c73650a090909686172646d6f646574696d65723d300a")
    (hex 36352 "0909656e640a09656c73650a09092d2d616e696d6174696f6e200a09096d2e75695f6479202b3d202e310a09096d2e75695f6f79202b3d206d2e75695f64790a09090a09096966206d2e75695f6479203e2035207468656e0a0909096269726463686f696365203d206d2e73656c0a0909206d656e75203d202267616d65220a090909626567696e5f67616d6528290a09090972657475726e0a0909656e64200a09656e640a656e640a0a66756e6374696f6e20647261775f6d61696e5f6d656e75286d290a096c6f63616c206f79203d206d2e75695f6f790a090a0970616c7428302c66616c7365290a090a09647261775f6c6f676f2834342c352d6f7929")
    (hex 36608 "0a090a092d2d706c617965722073656c656374696f6e0a097265637466696c6c283131322c38392b6f792c3132352c3131302b6f792c3132290a097265637466696c6c28322c3130332b6f792c3132352c3132342b6f792c31290a09666f72206b3d302c236d2e627574746f6e7320646f0a090969203d206d2e627574746f6e735b6b5d0a09090a09096f79203d20616273286f79290a09096966286b203d3d203133296f79203d202d6f790a09090a09097265637466696c6c28692e782c200a0909692e792d692e6f79202b206f792c200a0909692e782b692e772c200a0909692e792b692e682d692e6f79202b206f792c200a0909692e636f6c290a0909")
    (hex 36864 "73707228692e7370722c200a0909692e782b312c200a0909692e792b312d692e6f79202b206f792c0a0909312c692e7368290a09090a0909696620692e6e3d3d3133616e6420692e616374697665207468656e0a0909096f7072696e742822612067616d652062793a222c322c31332c203134290a0909096f7072696e74285b5b794f4c574f4f434c450a674f5553504f5552440a6e4f54474f594f4d450a73494d4f4e20742e5d5d2c322c3133290a0909096f7072696e74285b5b636f64652c6172740a636f64650a636f64650a6d757369635d5d2c34352c31332c203133290a0909656e640a09656e640a096f793d616273286f79290a090a092d2d2062")
    (hex 37120 "7574746f6e730a096c6f63616c2073656c3d6d2e627574746f6e735b6d2e73656c5d0a097265637466696c6c280a09322c39332b6f792c0a09322b2373656c2e6e616d652a382c203130322b6f792c31290a09776964652873656c2e6e616d652c342c39352b6f792c37290a0970616c7428290a090a092d2d20656e636167656420626972640a0970616c7428312c74727565290a097370722873656c2e626972642c362a382c372a38290a097370722833322c362a382c372a38290a0970616c7428290a656e640a0a66756e6374696f6e20647261775f6c6f676f28782c79290a092d2d226269726473220a096f78786c28226269726473222c782c792c31")
    (hex 37376 "30290a096f78786c282267756e73222c782b342c792b31352c2036290a090a092d2d2277697468220a096f7072696e74282277697468222c782b31312c792b3130290a090a096f7072696e74282277697468222c782b31312c792b39290a656e640a0a66756e6374696f6e206f78786c28742c782c792c636f6c290a092d2d63726564697420746f20667265647337320a09666f722069783d2d322c3220646f0a0909666f722069793d2d322c3420646f0a090909696620616273286978293d3d32200a0909096f7220616273286979293e3d32207468656e0a090909097072696e7428225c5e70222e2e742c782b69782c792b69792c31290a090909656e64")
    (hex 37632 "0a0909656e640a09656e640a090a09636f6c3d636f6c206f722037200a09666f722069783d2d312c3120646f0a0909666f722069793d2d312c3120646f0a0909097072696e7428225c5e70222e2e742c0a090909782b69782c792b69792c636f6c290a0909656e640a09656e640a656e640a0a66756e6374696f6e207769646528742c782c792c636f6c2c707265290a092d2d63726564697420746f20796f6c776f6f636c65207577750a0974313d20222020202020202020202020202020202021202324252627282920202c2d2e2f5b31323334355b375b393a3b3c3d3e3f285b5b635b6566635b696a5b6c5b5b285b285b73745b5b5b26797a5b5c5c5d27")
    (hex 37888 "5f605b5b635b6566635b696a5b6c5b5b285b285b73745b5b5b26797a7b7c7d7e220a0974323d2220202020202020202020202020202020215c223d2420202728292a2b2c2d2e2f303132335d353637385d3a3b3c3d3e3f406162636465666768696a6b6c6d6e6f7071727374757677785d7a5b5c5c5d5e5f606162636465666768696a6b6c6d6e6f7071727374757677785d7a7b7c7d20220a096e312c6e323d22222c22220a097072653d707265206f722022220a090a09666f7220693d312c237420646f0a09096c6f63616c2063686172203d2073756228742c692c69290a09096c6f63616c20633d6f72642863686172292d31360a09096e312e2e3d7375")
    (hex 38144 "622874312c632c63292e2e2220220a09096e322e2e3d7375622874322c632c63292e2e2220220a09656e640a090a09696628636f6c213d6e696c29636f6c6f7228636f6c290a097072696e74287072652e2e6e312c782c79290a097072696e74287072652e2e6e322c782b312c79290a656e640a0a0a2d2d3e380a2d2d64726f70730a66756e6374696f6e206d616b655f64726f7028782c792c7370722c747970652c71290a096164642864726f70732c7b0a0920783d782c20793d792c0a092062783d382c64793d382c0a09200a09207370723d7370722c0a0920747970653d747970652c0a09200a0920713d712c0a0920746f75636865643d66616c7365")
    (hex 38400 "2c0a0920636f6f6c646f776e3d302c0a09200a092064657374726f793d66616c73652c0a097d290a656e640a0a66756e6374696f6e207570646174655f64726f707328290a09666f72206420696e20616c6c2864726f70732920646f0a0909642e636f6f6c646f776e3d6d617828302c642e636f6f6c646f776e2d31290a09090a09096c6f63616c20746f7563686573203d20746f75636865735f72656374280a0909702e782b342c702e792b342c0a0909642e782c642e792c642e782b382c642e792b38290a09090a09096966286e6f7420746f756368657329642e746f75636865643d66616c73650a0909696620746f7563686573207468656e0a090909")
    (hex 38656 "0a0909096c6f63616c20636f6c3d370a0909096c6f63616c207478743d22220a0909096c6f63616c20646f5f707463203d2066616c73650a0909090a090909696620642e747970653d3d22616d6d6f22207468656e0a09090909642e64657374726f79203d20747275650a090909096c6f63616c2071203d20666c7228642e712a702e67756e2e6d6178616d6d6f290a09090909702e67756e2e616d6d6f202b3d20710a090909090a09090909646f5f7074633d747275650a09090909636f6c3d390a090909097478743d222b222e2e712e2e2220616d6d6f220a090909090a09090909736678283338290a090909090a090909656c7365696620642e747970")
    (hex 38912 "653d3d226865616c7468227468656e0a09090909642e64657374726f79203d20747275650a09090909702e6c696665202b3d20642e710a090909090a09090909646f5f7074633d747275650a09090909636f6c3d380a090909097478743d222b222e2e642e712e2e22206865616c7468220a090909090a09090909736678283338290a090909090a090909656c7365696620642e747970653d3d2267756e22200a090909616e64206e6f7420642e746f75636865640a090909616e6420642e636f6f6c646f776e3c3d30207468656e0a09090909642e746f7563686564203d20747275650a09090909642e636f6f6c646f776e203d2036300a090909090a0909")
    (hex 39168 "0909646f5f7074633d747275650a09090909636f6c3d360a090909097478743d642e712e6e616d650a090909090a09090909702e67756e6c735b702e67756e6e5d2c642e713d642e712c702e67756e6c735b702e67756e6e5d0a090909097570646174655f67756e2870290a09090909642e737072203d20642e712e7370720a090909090a09090909736678283336290a090909656e640a0909090a090909696620646f5f707463207468656e0a09090909666f7220693d312c3520646f0a09090909096d616b655f707463280a090909090909642e782b72726e642838292c0a090909090909642e792b72726e642838292c0a090909090909726e64283529")
    (hex 39424 "2b352c636f6c2c0a090909090909302e392b726e6428302e303729290a09090909656e64200a090909656e640a0909090a0909096d616b655f707463280a09090909642e782b342d28237478742a32292c0a09090909642e792b342c0a09090909726e642835292b352c372c0a090909092e39382c302c2d302e332c7478740a090909290a0909656e640a09090a0909696628642e64657374726f792964656c2864726f70732c64290a09656e640a656e640a0a66756e6374696f6e20647261775f64726f707328290a09666f72206420696e20616c6c2864726f707329646f0a090973707228642e7370722c642e782c642e79290a09656e640a656e640a0a")
    (hex 39680 "66756e6374696f6e20737061776e5f6c6f6f7428782c79290a096c6f63616c2072203d20726e642831290a090a0969662072203c202e303135207468656e0a09096c6f63616c2067203d20726e645f67756e28290a09096d616b655f64726f7028782c792c672e7370722c2267756e222c0a0909636f7079286729290a09656c736569662072203c202e303435207468656e0a09096d616b655f64726f7028782c792c37392c22616d6d6f222c312f34290a09090a09656c736569662072203c202e30373520616e642064656761706c7573203d3d2030207468656e0a09096d616b655f64726f7028782c792c37382c226865616c7468222c32290a090a0965")
    (hex 39936 "6c736569662072203c202e30313720616e642064656761706c7573203d3d2031207468656e0a09096d616b655f64726f7028782c792c37382c226865616c7468222c31290a09656e640a656e640a2d2d3e380a2d2d6465617468206d656e750a66756e6374696f6e206d616b655f64656174685f6d656e7528697377696e290a096c6f63616c206d203d207b0a0920207570646174653d7570646174655f64656174685f6d656e752c0a092020647261773d647261775f64656174685f6d656e752c0a0920200a09202063697263743d312c0a09202074696d65723d302c0a09202073686f77746578743d66616c73652c0a0920200a092020697377696e3d69")
    (hex 40192 "7377696e2c0a0920206e73746174733d302c0a097d0a090a096c6f63616c20742c74323d227265747279222c226368616e67652062697264220a09696628697377696e29743d22706c617920616761696e222c227469746c652073637265656e220a090a096d2e627574746f6e73203d207b7d0a096d2e627574746f6e735b315d3d7b0a09096e3d312c0a0909743d742c0a0909783d302c793d302c206f793d302c0a09096163746976653d66616c73650a097d0a096d2e627574746f6e735b325d3d7b0a09096e3d322c0a0909743d74322c0a0909783d302c793d302c206f793d302c0a09096163746976653d66616c73650a097d0a090a0972657475726e")
    (hex 40448 "206d0a656e640a0a66756e6374696f6e207570646174655f64656174685f6d656e75286d290a096d2e63697263743d6d696e286d2e63697263742a312e30352c363030290a090a092d2d636972636c652074696d65720a096966206d2e63697263743e3d363030207468656e0a09096966286d2e74696d65723d3d3029206d75736963283233290a09090a09096966286d2e74696d65723d3d32323029206d75736963283234290a09096966206d2e74696d65722536303d3d3539200a09090a09092d2d22706c6f6f702220736678206f6e20657665727920737461740a0909616e64206d2e6e73746174733c33207468656e0a09090973667828343129200a")
    (hex 40704 "0909096d2e6e73746174732b3d310a0909656e640a09090a09096d2e73686f77746578743d747275650a09096d2e74696d6572202b3d20310a09656e640a090a092d2d20627574746f6e730a096c6f63616c206f203d20300a096966206b6579626f61726420616e64206d2e74696d65723e31207468656e0a090969662862746e28e29d8e29296f3d310a090969662862746e28f09f85beefb88f29296f3d320a09656e640a090a09666f7220693d312c236d2e627574746f6e7320646f0a09096c6f63616c2062203d206d2e627574746f6e735b695d0a09096c6f63616c20743d6d2e74696d6572202f203130300a09090a09096c6f63616c206f78203d20")
    (hex 40960 "23622e742a320a0909622e78203d2063616d78202b203634202d206f78200a09092b20636f7328742b692f3130292a312e350a0909622e79203d20312f74202b203830202b20692a3135200a09092b2073696e28742b692f3130292a312e350a09090a0909696620746f75636865735f72656374286d782c6d792c0a0909622e782d342c622e792d342c0a0909622e782b23622e742a342b332c20622e792b3929207468656e0a0909090a0909096966286e6f7420622e61637469766529736678283433290a090909622e616374697665203d20747275650a090909622e6f79203d20330a0909096966206c6d62207468656e0a090909096f203d20622e6e0a")
    (hex 41216 "090909656e640a0909090a0909096d2e73656c203d20690a0909090a0909656c73650a090909622e616374697665203d2066616c73650a0909090a0909656e640a09656e640a090a096966286f3d3d312972756e28746f737472286269726463686f69636529290a096966286f3d3d322972756e28222d22290a656e640a0a66756e6374696f6e20647261775f64656174685f6d656e75286d290a092d2d636972636c657320616e696d6174696f6e0a0970616c7428302c66616c7365290a0970616c7428312c74727565290a096c6f63616c20636f6c2c63322c63332c63343d302c312c322c390a096c6f63616c20747874636f6c203d20370a096966206d")
    (hex 41472 "2e697377696e207468656e0a0909636f6c2c63322c63332c63343d31352c392c382c320a0909747874636f6c203d2031300a090969662874282925323c3129747874636f6c203d20390a09656e640a090a096c6f63616c20782c79203d20702e782b342c702e792b340a096c6f63616c2063203d206d2e63697263740a096369726366696c6c28782c792c63202020202c6334290a096369726366696c6c28782c792c632a2e37352c6333290a096369726366696c6c28782c792c632a2e35202c6332290a092d2d73707228702e7370722c702e782c702e79290a096369726366696c6c28782c792c632a2e32352c636f6c290a0a0970616c7428290a090a09")
    (hex 41728 "2d2d74657874202620627574746f6e730a096c6f63616c20743d6d2e74696d65722f3130300a096c6f63616c207478743d6d2e697377696e20616e64200a0920202022636f6e67726174732122206f72202267616d65206f766572220a090a096f78786c287478742c0a09202020202063616d782b33302b636f732874292a332c0a092020202020312f74202b32302b73696e2874292a332c20747874636f6c290a0920202020200a09666f72206220696e20616c6c286d2e627574746f6e732920646f0a09096c6f63616c2061203d2022220a09096966206b6579626f617264207468656e0a09090961203d2022f09f85beefb88f220a090909696628622e")
    (hex 41984 "6e203d3d2031292061203d2022e29d8e220a0909656e640a09090a0909696620622e616374697665207468656e0a0909096f7072696e7428612e2e622e742c622e782c622e792d622e6f792c312c37290a0909656c73650a0909096f7072696e7428612e2e622e742c622e782c622e792c31342c31290a0909656e640a09656e640a090a092d2d73746174730a096c6f63616c20693d300a09666f72206b2c7620696e20706169727328737461747329646f0a0909696620693c6d2e6e7374617473207468656e0a090909746578745f79203d20692a382b312f742b34302b73696e28742b2e33292a330a0909096f7072696e74286b2c63616d782b33352c74")
    (hex 42240 "6578745f79290a0909096f7072696e7428762c63616d782b38302c746578745f792c203133290a0909656e640a0909692b3d310a09656e640a090a09666f7220693d302c3620646f0a09096c6f63616c207478743d22e29692220a0909696628693c3d7761676f6e5f6e297478743d22e29688220a09096966206e6f74206d2e697377696e207468656e0a0909096f7072696e74287478742c2063616d782b33372b692a382c0a090909312f742b37302b73696e2874292a332c2037290a0909656e640a09656e640a090a092d2d68617264206d6f64652070726f6d70740a096966206d2e697377696e207468656e0a09096c6f63616c207478743d22686f6c")
    (hex 42496 "64207468652027692720627574746f6e5c6e6f6e20746865207469746c652073637265656e5c6e746f20756e6c6f636b2068617264206d6f64655c6e220a090969662864656761706c7573213d30297478743d2262726f2077686174202121215c6e74686973206d6f646520776173206e6f74205c6e737570706f73656420746f20626520706f737369626c652021220a09096f7072696e74287478740a09092c63616d782b32352c312f742b37302b73696e2874292a322c203133290a09656e640a656e640a0a5f5f6766785f5f0a303030303030303030303064353030303030303035643030373737373737373730303030303030303131313131313131")
    (hex 42752 "37373737373737363636363636363664343434343434343434343434343434343434343434343434343434343434343465656565656565656565313131316565313165656565313165653131313165650a30303030303030303030303537353030303030353735303037373737373737373664303030303636313131313131313137643631313664643635646464643535323434343434323234343434343434343434343434343434323434313134323265656565656565656565313131316565316565656565653165653131313165650a30303730303730303030303537373739343436373735303037373737373737376464643030366464313131313131")
    (hex 43008 "313137363131313136643664646464646435323232343434343432323232323232323434343434343434323232313134343465653131313165656565313131316565656531313131656565653131313165650a30303037373030303037303035373639393939373664303039393939393939393037373736373630373737373737373737363131313136643664646464646435343434343432323432323232323232323434343434343434343434643132323465653131313165656565313131316565656531313131656565653131313165650a3030303737303030373736303439393939393939393930303737373737373737303636363636363039393939")
    (hex 43264 "3939393937363631313636643664646464646435343434343434343434343434343434343434343434343434343434643434343465653131313165656565313131316565656531313131656565653131313165650a30303730303730303737373034353539393939393539303031313131313131313664643030646436373737373737373737363631313636643664646464646435343232323434343434343434343434343434343434343434343232643434343465653131313165656565313131316565656531313131656565653131313165650a303030303030303036373930373438353539353539343030313131313131313164643030303064643737")
    (hex 43520 "37373737373737643636363664643635646464643535343434343434343432323232323232323232323232323232343434363434343465653131313165656565313131316565656531313131656538656565656565380a30303030303030303039393036373838393938383430303031313131313131313030303030303030373737373737373736646464646464646435353535353535323232323232323232323232323232323232323232323232323232363232323265653131313165656565313131316565656531313131656538386565656538380a37373737373737373034393930373737373131373630303037373737373737363232323232323232")
    (hex 43776 "343434343434343131323231313131313535353535353535343432343432343431343434343434343131316262313131343434363434343436363636363636363134343434343431656565656565656538383865386565380a37373737373737373030306464643637373737373730303037303030373730643232323232323232343434343434343132313132343131313535353535353535343432343432343431343434343434343131313333316231323434363434323236363636363636363134343434343431656565656565656538383865386565380a3737373737373737303064643636363636643838363730303730303737303064343234343434")
    (hex 44032 "3434343434343434343131313434343432313030303030303030343232343434343431343434343434343162313333313331323232363434343436363636363636363134343434343431313131313131313138383865386565380a37373737373737373030353564646464643238653836303037303737303030643234343434343434343434343434343131323234343432313030303030303030343234343434343231343434343434343133313333333331343434363431313436363636363636363134343634343431313131313131313138383865386565380a373737373737373730353535373737376432383838363530373737303730306434323434")
    (hex 44288 "34343637343434343434343132343232343232313030303030303030343234323434343231343434343434343133333333343131343434643134343136363636363636363134343334343431313131313131313138383865386565380a37373737373737373536643535363636366432383637353537373037303030643234343434343434343434343434323132343432323231313030303030303030343434323434343231323434343434343131343333343131343264646434343137373737373737373134623333343431313131313131313131383865386565310a37373737373737373564643535363636363636373764353537303730303030643232")
    (hex 44544 "343434343434323232323232323131323432343432313030303030303030343434343434343431323232323232323131343434343131313134343434313464646464646464643134626233343431656565656565656531313865386531310a37373737373737373035353530303030303030303535353036646464646464363234343434343432323232323232313131323231323232313030303030303030343434343432343431313232323232323131323232323131323231313131323264646464646464643134623333343431656565656565656531313131313131310a3434343434343431666666666666666631313131313131313131313131313131")
    (hex 44800 "3131313131313131313131313131313134343434343434313131313131313131656565656565656565656565656565653131313131323232323232313131313136363131313131313134343434343431313131313131363631313164643131310a34343434343434316634343434343466666666666631313131313131313131313134343434343434343434343434313134343434343434313131313131313131656565656565656565656565656565653131313132323232323232323231313136363631313131313134343434343431313131313136363631313131643131310a343434343434343166346634663466666634346666313131313131313131")
    (hex 45056 "31313134343434343434343434343434313134343434343434313131313131313131383838383838383865656565656565653131323232316431643164323232313136363631313131313134343434343431313131313136363631313131643131310a32323232323232316634663466346666663466666666666666666666666666663134343434343434343434343434313132323232323232313131313131313131383838383838383865636337373763653131323264316431643131643232313136363631313131313134343434343431313131313136363631313131643131310a64313631363164316666666666666666663466346666343434343434")
    (hex 45312 "343434663134343434343434343434343434313164313638363164313131313131313131383838383838383865633737376363653032326431643164643164313132323035353631313131313134343434343431313131313136353531313164643131310a36313631643164313434343434343434666666346666346634663466346634663134343434343434343434343434313136383638643964313131313131313131383838383838383865373737646464653032323031316432326431646432323036363536363631313134343434343431313136363635363631313164313131310a3631643164316431343234323432343466663434666634663466")
    (hex 45568 "3466346634663132323232323232323232323232313136316439643164313131313131313131383838383838383865656565656565653032326464643232323264303032323036363636363636313134343434343431313636363636363631313164313131310a32323232323232313434343434343434666666666666346634663466346634663164316431643164316431363136313132323232323232313131313131313131383838383838383838383838383838383032323030643232323264646432323036363636363636313134343434343431313636363636363631313164313131310a363636363636363131313131313131313434343434666666")
    (hex 45824 "66666666666666663164316431643136313631373137313134343434343434313131313131313131666666666666666630303030303030303632326464366432326436363632323636363636363636313134343434343431313636363636363631313131313131310a36363636363636316666666666666666343232323434343434343434343434343164313631363137623731373137313134343434343434313131343131343431666666666666666630303030303030303632323636643664643664366432323635353635353536313134343434343431313635353536353531313164643131310a36363636363636313737373737373737343232666666")
    (hex 46080 "666632323232323232343136313763373937313762363136313134343434343434313134343434313434666633666666666630303030303030303636323264363664366436643232363635353536363635313134343434343431313536363635353531316464646431310a64646464646464313737373737373737343434663466346632343234323432343137633731376136623662366264313132323232323232313132343234323134666633663366666630303030303030303636323232643664366436323232363635353536363636313134343434343431313636363635353531316464646431310a3531643164313531666666666666666631313166")
    (hex 46336 "6666666634343434343434343137633663363236623662643264313164313661363164313232323232343131666633663366666630303030303030303636363232323232323232323636363635353536363636313132323232323231313636363635353531313564643531310a64316431353135313434343434343434313131343434343431313131313131313136633632363264326432643264313164396461366136313234343234343431666666666666666630303030303030303737373737323232323232373737373735353536363636313132323232323231313636363635353531313135353131310a643135313531353134313131343134343131")
    (hex 46592 "31343232323431313131313131313136326432643264326432643264313164316439643136313132343232343231666666666666666630303030303030306464646464646464646464646464646435353535353535313131313636313131313535353535353531313131313131310a64646464646464313434343434343434313131343434343431313131313131313132323232323232323232323232313132323232323232313131323131323131666666666666666630303030303030306464646464646464646464646464646435353535353535313131313636313131313535353535353531313131313131310a30303030303030303030303030303030")
    (hex 46848 "303030303030303030303030303030303030363664363030303030303030303030303030303030303030366436643030303030386530303030303030303030303030303030303030303030303030303030396161616139303030373737373030303131313131303030323232323230300a30303030303030303030303030303030303030303030303030303030303030303030363664363030303030303030303030303030303030303064303030303630303038383832383030303535353030303030303030303030303030303030303039613930303961393037373737373730313637383736313032396139613932300a3036303030303030303630303030")
    (hex 47104 "3030303030303030303030306464643030303030306464303030643030646430303064646430303064643630303030303064656538383238386534343464356464643030353030303830306436366161393861393030303039613730303036373737313638383836313032393234323932300a30303636363630303030643636363636303434366436643634343636363430303064363636363636363434363636363636363436363664646434343535303036383838383238386564643436353636366436363637383838303061393131613861303030303030613030303030363737313637383736313032396139613932300a303436646464303034343435")
    (hex 47360 "30343430343434303530303034346464643464643464343434303030363434363636363630343430353030303434343435303064383838383238386535353464356464646464646438373838303961363535613061303030303030613030303030363737313736363637313032343934393432300a34343435303030303434303030303030343430303530303034303430353030303434303530303030643030353035303030343430383830303434303030303036383838383238386564643530353030303034343030303830396135396161393061393030303039613730303036373737313564646435313032343934393432300a34343030303030303030")
    (hex 47616 "303030303030303030303030303030303430353030303030303030303030303030353030303030303030393930303036303030306430303038383832383035353430303030303034303030303030613530303030303039613930303961393037373737373730303131313131303030323232323230300a30303030303030303030303030303030303030303030303030303030303530303030303030303030303030303030303030303030383830303030643664363030303030303030303030343430303030303030303030303030303030303030303030396161616139303030373737373030303030303030303030303030303030300a3131313131313131")
    (hex 47872 "3232323232323232313131313131313131313131313131313232323232323232313131313131313135353535353535353434343434343434353535353535353532323232323232323434343434343434353535353535323830363030303030353030303030303030303636373637373030303030303030300a31313131313131313232323232323232313131313131313131313131313131313232323232323232313132656532313135353535353535353434343434343434353535353535353532323232323232326364343434343434353535353238383830343630303035343030396161393030363636363838363730303865653830300a313135646435")
    (hex 48128 "31313232323232323232313131313131313131313238383832313232323232323232316565656565323135353637373635353434343436373736353535656565353532323232323231306363636434343434353535323838383830353939393939363039613737613930356336383738383630386537376538300a31376464646435313232353333353232313131313131313131323838383838323232323232323130326565656666653135373737373737353434343637373737356566666666663232323232323030303763636364343434353564383838653730393139393939313061373737376130363636383838383630653737373765300a35353764")
    (hex 48384 "323264313233333333333961313131313131313131383232383838383932323232313030656531656630653164363737373636643434373737376464326666666666323232323231303030306337376363643434353536363737373730393931373731393061373737376130353536643838643630653737373765300a31353764383832353533333333616161313131313131313131323637383836366161393230303961656531656537653164646437376464643434373737643036323266663232303532313030303030303730646331313134353636373737373730303737373437303039613737613930303636366464363030386537376538300a3131")
    (hex 48640 "6438313838643333333339616132313131313131313131363737323636366161616161306363653231323766373139303037373030393434363737363036353032386530303534393939343030303730306330313131353130616137373730303936363639303030396161393030303564303035643030303865653830300a31316438313838643330303361343432313132343231313131373730363631313961616130633163656531316666663137393039613039373434343937373636356638383838666532313130393939303737376363303434643061323261373030303434303434303030303030303030306435303064353030303030303030300a")
    (hex 48896 "31356464383864643330313339343434393934343432313131373630353636363939616130633163656532313030663137373739393737373434393961613737663832383832386632323232613030303137373737363434363761323131613030303432323230303030303030343930373737303030303063636363636363630a35336464646464353533333333393934613934313432323131363030303636366539393039616363326565303030313136373939613937373439396137373737663265323265326632323232613931303131373737363434363739313139393730343237373732303030303034303061303030303030303063636337376363")
    (hex 49152 "630a33336433646464313235333333333339316137343232323231363130303636383865303061616137316565303031313130373139613136373439613437373737666666656566666532323232376161396331373737343434363738393939373734323731663137303030323837323030373737303030303063636363636363630a3332333364333531323233333333333231363737373232323131313238383838323830373737373731326565323131313036303061303137343434343737373735666565656666353232323237373761636331373634343437373838383837373234663166316630303238383837323037373730303030306363373737")
    (hex 49408 "6363630a32323233333333313232353333333732313136373737363131313238383838323235373737373737653131656532313130313030393030363434346437373737356665656565323532323236373737376364373134343434373765383838373734323766666634343038313838383130373737303030303063636337376363630a323232323233323232363535373734343431316531653131313932383838323832373737373737376565313265653131303030303030313064363636363737373535326565653235323232363737373764373736343434343737373838653737323437373737373030383831383138303030303030303030636363")
    (hex 49664 "37376363630a36323632363232366436366435353434323465313165313161613838383961383035373737373737656532316565323131303030303031303636363636363737353535656565653232323237373737373737373434343434373737373737373730323437373730303032383838383230303030303030303063633737373763630a36363636363236363636363636646435313232346534323163636138386361613030303537373737656565313265653131303031303030303636363636363636353535326565656532323237373737373737363434343434373737373737373730303232303232303030323838323030303030303030303063")
    (hex 49920 "636363636363630a31313131356431313131313133623131313131313131313131313238386531313130303031313131313131656565653131313136373731313131313136373131313131316565663131313030303031316463636363643131313131313838383131316436366464353030336262623030303030303030303030313130303131300a3131313564646431313131333333623131313131313131313132373037383731303737396161303131313165373037353131363037396131313131363737373131313131663065653130303030303031313163373737633131313738383838313164363737376464303362626262623030303030303030")
    (hex 50176 "3031373731313737310a31313135326464313131313330616131313131313131313131323737373037373063373939393930653131316565313531313637373939613131313630373939353131313166663130306137303939393131316437303764313637373739616136373737373736643333316262333130303035303530363031373130303137310a353131336464373731313133336139393131313134343131313838373030363630373738383838393265656565653131313030303035313931313636373737313135353434666631303030306161313131313131643737313637373037373838373737323737376433336231623133303030306565")
    (hex 50432 "66303030313030303031300a35363632333333316464646433333431313134313436393161613838383831313030373730313138313232656531313131303030303035313636363636363731353435353434653130303037373631316364376363633731363737373737373837373238653737363333336262626230303030666666303030313030303031300a64353636323232313136363634343431313131343631313131626161383231313030303030313131313137313731313130303037303030313536363636373731666566663434313130303037373631313163643763373631363637373737363136373738373737363232343434663430303035")
    (hex 50688 "303530363031373130303137310a31643636363631313131363434343131313131313131313131316363323131313130303031313131313137313731313131373730303031313135373737363131316531316531313130303737363631313131373737363131313636373736313131373737373631313032323232323030303030303030303031373731313737310a3131383138313131313139313931313131313131313131313131353135313131316331633131313131313231323131313131393131393131313131653165313131653131653131313030373535303031313131353135313131313931393131313131373631313131303234346634303030")
    (hex 50944 "3030303030303030313130303131300a39333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339")
    (hex 51200 "33393339333933393339333933393339330a38323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832633038323932383263303832393238326330383239323832633038326330383238326330383239323932393239323932393239323932383263303832393238320a38326330393238326330393238326330393238326330393238326330393238323832383263303932393263306330633039323932633038323832633039323832383238323932383238323832393238323832383239323832383238323932383263303832393238323832383239")
    (hex 51456 "323832383238323932383238323832633038320a30323133373237323732313330323732373231326131373237323732373261313732313232323930393039303930393039303930393035323732313231323132643063316130613064306130613063316430613061306331643063336430323233326430363063316331633163316331633163316331363064303132313237320a3133643063336331643063336331643063336331643063336331643031323132373265326430313231326430643064303132313264303430343064303132363336333432353236323732373237323732313237323732373237323732373237326430613061306331613061")
    (hex 51712 "3061306130613061306130633161306130643037320a31323732373237323732373237323732373237323732373237323732373237323732313332333930393039303930393039303930393035333732303230323032643037323732313364303732373237326430373237323133643036316430323333336430663238313833383338333833383338333831663264303132373237320a313364303732373264303732373264303732373264303733373264303132373237326533643037323732383238323832373237326430383238323832313237323632343335333633343235323632363331333132373237323732313231333732643064333732373264")
    (hex 51968 "33373237326433373237326433373237326433643037320a37323732373264326432373237323732653037323732373264326432373237323732373237323930393039303930393039303930393037323732373230323032643037326633643364303732663364336430643366333732643037326430373237326430663238313833383338333833383338333831663264303132373237320a37326430343138323832343138323832343138323832343138326430313237323732373264303732373261313132613137323732643037323732373237323732373237323432353234333533373237326436313334323532313331323732373264303232333237")
    (hex 52224 "323732373237323732373237323732373237323133643037320a37323732643364316432643337323732643037323732643364326431643337323732373237323732373237323732643637326436373237323732373237323032643037323732373264303832343138326430373237323732643037336430373237326430663238313833383338333833383338333831663264303132373237320a3732643037323732373237323732373237323732643637326436643037323732373265326430373237323732373237323732373264303732373263306332373237323732343335333732373237323732373237323433353331323732373237326430323333")
    (hex 52480 "3337323732373237323732373237323732643630323132643037320a37323732373264326431373237323732643037323732373264326432373237323732373237323732373237323732373237323732373237323732373237323732383238323431383238326131373261313832383234313832383234313832373237326430393039303930393039303930393039303930393064303732373237320a373264303732373237323732373237323732373237323732373264303732373237326533643038323932393239323932383234316430373237326430633337323732373231323133373237323732373237323732363337323732373237323732383238")
    (hex 52736 "32383238323832383237323732373238323832383238323832383237320a37323732643364326432643337323732663037323732643364316432643337323732373237326331613061306130613061306130633137323732373237323732373237323732373237323732373237323732373237323732373237323732373237326430613161313732373237323732373237326633643164303732373237320a37326430613137323732373237323732373237323732643661316430373237323732373264303732373237323732373264363732643037323732643037323732373237323133373237323732373237323732373236323732373237323732373237")
    (hex 52992 "323732373237323732613137323732373261313732373237323732373237320a37323732373239313531373237323732663137323732373239313531373237323732373264336431373237323732373237326131643237323732373237323732373237323732373237323732373237326436373237323732373237323732373237326430613161316131373237323732373237323732643364303732373237320a3732383238323832383238323832343134313832383238323832383237323732373237323832373237323732373237323732373238323732373264306332313231333432353237323732343235323732373236333632363237323732373237")
    (hex 53248 "3237323732373237323732373237323732373237323732373237323732373237320a37323732373237323732373237323732373237323732373264363732373237323732373237326432373237323732373237323732643164333732373237323732373237323732373263303832343138326330383234313832633034316330373237323832383238323832383238323832343134313832383238323732373237320a373261313132313231323732373237323732373237323732313237323732373237323732373237323732633039326330373237323732373237326430633331333732343335333432353234333533313231323432353231323132313337")
    (hex 53504 "32373237323732373237323732373237323732373237323732373237323732373237320a37323732373237323732373237323732373237323732373237323732373237323732373237323931613061306130613063316130353137323732373237323732373237323732303264303732373239316430373237323732643031326430303237323732373261313132313232323332373237323232333237323732373237320a37323732373237323732373237323732373237323732373237323732373237323732373263303732373264303430643037323732633038323832643037323732373237323633343335333732373237323133343335333732373231")
    (hex 53760 "323133373263303832383238323832633037323732373263303832383238323832633037320a37323133373237323732373263323732643137326532373264363732373237323732373237323732643337323732643337326433373237323732373237323732373237323033313264303432373266336430663361306633643031326430313237323732373237323732373232333333373237323233333337323732373237320a3732373237323732373237323732313237323732373237323732373237323732373265326430373237326430343064303732373264306132623264306332373237323732373231323133373237323732373236323633373237")
    (hex 54016 "3237323732373264303232333230323133383237323732373238323133303334323532643037320a31323132313330323132373263333732643337326533373237323732373261313132373237323732373237323732373237323732373237323732373237323732373237323133363264303433373231326430373266333132643031336430313237323732373237323732373237323732373237323732373237323732373237320a373237323732373237323732313231323133613137323732373237323732373237326533643037323732643034306430373237326430613362336430633337323732373237323132373237323732373237323732313337")
    (hex 54272 "32373237323732373264303233333331333732343137323732373234313732313334333533643037320a38323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238320a38323832393238323832383239323832383238323932383238323832393238323832383238323832383238323932383238323832383238323832383239323832383238323932383238323832393238323832383239")
    (hex 54528 "323832383238323932383238323832393238323832383239323832383238323932383238323832393238320a39333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a3933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339")
    (hex 54784 "3339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a63316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163310a633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163")
    (hex 55040 "31633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163310a39333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a39333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339")
    (hex 55296 "333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a38323832393238323832633039323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832633038323932383238323832393238323832383239323832633038323932383238323832393238323832383239323832383238323932383238323832393238320a3832383238323932383238323832393238323832383239323832383238323932383263303832393238326330383238323832383238323832383238326330383238323832383238323832383238")
    (hex 55552 "3238323832383238323832383238323832383263303832383238323832383239323932383239323932633039333933393339330a61313732373237326131643061313732373237326432373237323133313331333732653263323732643163323732633163313732653264313732653263323732643063323732373237323732373237323732373237326532643034323033373263316331613262326331633163316132623263316331633161326232633163310a373231336430383038303830623038303830383038306230383038303830643037326430343235323632643031323132373237323732313232323332643037323732303231333732373237")
    (hex 55808 "32313331333732373231323133313237323132313364303132373237323732373237323732373237323732383239323932633039330a63326432373264316532643037323732373237323931613061306130633163313732653363333732643363333732373237323732653364333732653363333732643063333732373237323432353237323732373237326533643034333732373237323730613362333730613137306133623337306131373061336233373037320a63303032663038303830383062313830383038303830623138303830383066303732643034333533363364303132643637326436373231333233333364303732373263326432373263")
    (hex 56064 "326432373263326432373263326432373263326432313364303132373237323732373237323732373237323732663237323732383263310a63336433373264336533643037323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732643061313732373237323433353336333132373237326131643030323732373237323730373037303730373237303730373037303732373037303730373037320a6430373266313830383038303830383062306230383038303830383038306631373264303732373237326430373237326330373237323732323233326430373237326333643337")
    (hex 56320 "3263336433373263336433373263336433373263336433373264303732373237323732373237323732373237323732663237323732663333310a37323732373237323732643031333732313365306332643137326432653237323732373237323732373261313732373237323732613137323732373237323732383238323431383238323832633038323832383234313832383237323732373237326632373237326632373266323732373266323732663237323732663237320a643037326131393038303830383038306231623138303830383038303930613137326430373237323732643037323732643064363732373231323333643037323732373237")
    (hex 56576 "32373237323732373237323732373237323732373264363732373236303732373237323732373231323732373237323732663237323732373233310a37326332643165323732643032323332613164306333643337326433653337323732363337323732643364326633373237326633643164333732373236323732373237323732373232323332643030323032303337323732373237323732373237326632373237326632313366323732373266323032663237323732663237320a38323732373237323930393039303930393039303930393039303930373237323732383238323832343164303732373264303732373237323132313264303732353035")
    (hex 56832 "303530353035303530353035303530353035303530353035303530353036303732373237323732373231323732373237323732663237323732663333310a37326333643365333732643032333333313364306131373237323732373237323732363237323732373264316633643637326633643237323732373236323732373237323732373232333333643031323033373237323732373237323732373237326632373237326632313366323732373266323133663237323732663237320a3732373237323732373237326436373264363732643637323732373237323732373237323732373237323832343134313832383238326330383238323832373230")
    (hex 57088 "3130313031303130313031303130313031303130313031303130313031303136303732373237323732373231323732373237323732663237323732373233310a37323732373237323732663037323132643664306332373264313732373237323732363337323732643364326436663366336436643264333732373236333732633038323431383238323832643038323832383234313832633037323732373237326632373237326632313266323732373266323032663237323732663237320a633037323732633237326431373265323732373263323732643137326532373237323732373237323732373237323732373237323132643032323332373237")
    (hex 57344 "32333033303330333033303330333033303330333033303330333033303330333036303732373237323732373231323732373237323732663237323732663333310a37323732373237323732663137323732373264306333373264333732373237323732373237323732373239316130613061306130353137323732373237323732643037323732373230323632663061313732373237323732643037323732373237326632373237326632373266323732373266323732663237323732663237320a64303732373263333732643337326533373237326333373264333732653337323732373237323732373237323732373237323732373266303233333337")
    (hex 57600 "323732373237323732373237323732373237323732373237323732373264363732373236303732373237323732373231323732373237323732663237323732373233310a37323732373237323732373237323732373264306131373237323732373237323732373237323732373237323732373237323732373237323732373237323732643030333732373237323732663137323732373237323132643061313732373237326331373237326331633163313732373263316331633137323732633137320a6430373237323732373237323732373237323732373237323732373237323732373237323732373237326330613137323732373237326631373237")
    (hex 57856 "3237323732373263326432373263326432373263326432373263326432373263326432373264303732373237323732373237323732373237323732663237323732663333310a32323332373237323732373237323732373264306332643237326431653237323732653263323732643163323732373237323732653264313732653263323732643034323032373237323732373237323732643630333633643032323332373265323730663366336532373063326633663365323730633266336633373063320a383237323732373237323732373237323732373237323732373237323732373237323732373232323332643037323732373237323732313237")
    (hex 58112 "32373237323732373263336433373263336433373263336433373263336433373263336433313364303132373237323732373237323732373237323732663237323732633039330a32333333313331326131373237323732613164306333643337326433653337323732653363333732643363333732633163313732653364333732653363333732643034333632303337323732373237326436303331333632643032333333373265333730313366336533373063336633663365333730633366333132373063330a37323732373237326332373264313732653263323732643137326532373237323732373237323132333364303732373237323732373237")
    (hex 58368 "323732373237323732373237323132373237323732313231333133373237323732373237323732313364303132373237323732373237323732373237323732633038323832383239330a38323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383238323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238320a3832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238")
    (hex 58624 "3239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383238323832383239323932383239323932383239333933393339330a39333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339")
    (hex 58880 "33393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339330a63316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163310a63316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163")
    (hex 59136 "316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163310a5f5f6c6162656c5f5f0a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 59392 "666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 59648 "6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666666666666666666666666666666666666666666666666666666666")
    (hex 59904 "66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666")
    (hex 60160 "666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737666637373737373737373737373737373737373766666666666666666666666666666666666666660a6666666666666666666666666666666666666666666637373737373737")
    (hex 60416 "3737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737666637373737373737373737373737373737373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868683737666637376868686868686868686868686868373766666666666666666666666666666666666666660a666666666666666666666666666666666666666666663737686868")
    (hex 60672 "68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868683737666637376868686868686868686868686868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616168683737373737376868616161616161616161616868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768")
    (hex 60928 "686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616168683737373737376868616161616161616161616868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616168686868686868686868616161616161616161616868373766666666666666666666666666666666666666660a6666666666666666666666666666666666666666666637")
    (hex 61184 "3768686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616168686868686868686868616161616161616161616868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616161616161686861616161616161616161616161616868373766666666666666666666666666666666666666660a666666666666666666666666666666666666666666")
    (hex 61440 "66373768686161616161616161616161616161686861616161616161616161616161616868616161616161616161616161616168686161616161616161616161616161686861616161616161616161616161616868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616868616161616161686868686868616161616161686868686868616161616161686861616161616168686161616161616868616161616161686861616161616168686868686868686868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666")
    (hex 61696 "666666373768686161616161616868616161616161686868686868616161616161686868686868616161616161686861616161616168686161616161616868616161616161686861616161616168686868686868686868373766666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616161616161686868686868616161616161686868686868616161616161616161616161616168686161616161616868616161616161686861616161616161616161616161616868373766666666666666666666666666666666666666660a6666666666666666666666666666666666")
    (hex 61952 "6666666666373768686161616161616161616161616161686868686868616161616161686868686868616161616161616161616161616168686161616161616868616161616161686861616161616161616161616161616868373765666666666666666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616168686868686868686868616161616161686868686868616161616161616161616868686868686161616161616868616161616161686861616161616161616161616161616868373765656565656666666666666666666666666666660a666666666666666666666666666666")
    (hex 62208 "66666666666666373768686161616161616161616168686868686868686868616161616161686868686868616161616161616161616868686868686161616161616868616161616161686861616161616161616161616161616868373765656565656565666666666666666666666666660a66666666666666666666666666666666666666666666373768686161616161616161616161616161686837376868616161616161686837376868616161616161616161616161616168686161616161616868616161616161686861616161616161616161616161616868373765656565656565656566666666666666666666660a66666666666666666666666666")
    (hex 62464 "666666666666666666373768686161616161616161616161616161686837376868616161616161686837376868616161616161616161616161616168686161616161616868616161616161686861616161616161616161616161616868373765656565656565656565656666666666666666660a66666666666666666666666666666666666666666666373768686161616161616868616161616161686868686868616161616161686868686868616161616161686861616161616168686161616161616868616161616161686868686868686868686161616161616868373765656565656565656565656566666666666666660a6666666666666666666666")
    (hex 62720 "6666666666666666666665373768686161616161616868616161616161686868686868616161616161686868686868616161616161686861616161616168686161616161616868616161616161686868686868686868686161616161616868373765656565656565656565656565666666666666660a66666666666666666666666666666666666666666565373768686161616161616161616161616161686861616161616161616161616161616868616161616161686861616161616168686161616161616161616161616161686861616161616161616161616161616868373765656565656565656565656565656666666666660a666666666666666666")
    (hex 62976 "66666666666666666666656565373768686161616161616161616161616161686861616161616161616161616161616868616161616161686861616161616168686161616161616161616161616161686861616161616161616161616161616868373765656565656565656565656565656566666666660a66666666666666666666666666666666666665656565373768686161616161616161616161616161686861616161616168686868686868686868686868686868686868686868686868686868686868686868616161616161686861616161616161616161686868686868373765656565656565656565656565656565666666660a66666666666666")
    (hex 63232 "666666666666666666666565656565373768686161616161616161616161616161686861616161616168686868686868686868686868686868686868686868686868686868686868686868616161616161686861616161616161616161686868686868373765656565656565656565656565656565656666660a66666666666666666666666666666666666565656565373768686161616161616161616161616161686861616161616168683737686837376868373737373737686837373737373768683737686837376868616161616161686861616161616161616161686868686868373765656565656565656565656565656565656566660a6666666666")
    (hex 63488 "6666666666666666666666656565656565373768686161616161616161616161616161686861616161616168683737686837376868373737373737686837373737373768683737686837376868616161616161686861616161616161616161686868686868373765656565656565656565656565656565656566660a66666666666666666666666666666666656565656565373768686868686868686868686868686868686868686868686868683737686837376868686837376868686868683737686868683737686837376868686868686868686868686868686868686868686868686868373765656565656565656565656565656565656565660a666666")
    (hex 63744 "66666666666666666666666666656565656565373768686868686868686868686868686868686868686868686868683737686837376868686837376868686868683737686868683737686837376868686868686868686868686868686868686868686868686868373765656565656565656565656565656565656565660a66666666666666666666666666666665656565656565373768686868686868686868686868686868686868686868686868683737686837376868686837376868686868683737686868683737373737376868686868686868686868686868686868686868686837373737373765656565656565656565656565656565656565650a66")
    (hex 64000 "666666666666666666666666666665656565656534373768686868686868686868686868686868686868686868686868683737686837376868686837376868686868683737686868683737373737376868686868686868686868686868686868686868686837373737373765656565656565656565656565656565656565650a6666666666666666666666666666666565656565653437376868686868686868686868686868686868686868686868686868373737373737686868683737686868686868373768686868373768683737686868686868686868686868686868686868686868683737656565656565656565656565656565656565656565656565")
    (hex 64256 "0a66666666666666666666666666666665656565653434373768686868686868686868686868686868686868686868686868683737373737376868686837376868686868683737686868683737686837376868686868686868686868686868686868686868686837376565656565656565656565656565656565656565656565650a666666666666666666666666666666656565656534343737373737373737373737373737686868686868686868686868686837373737373768683737373737376868686837376868686837376868373768683737686868686868686868686868686837373737373765656565656565656565656565656565656565656565")
    (hex 64512 "65650a66666666666666666666666666666665656565343434373737373737373737373737373768686868686868686868686868683737373737376868373737373737686868683737686868683737686837376868373768686868686868686868686868683737373737376565656565656565656565656565656565656565656565340a66666666666666666666666666666665656565343434343434343434343437373737373768683636363636363636363668686868686868686868686868686868686868686868686868686868686868686868373768683636363636363636363668683737656565656565656565656565656565656565656565656565")
    (hex 64768 "656534340a66666666656565656565656666666665656565343434343434343434343437373737373768683636363636363636363668686868686868686868686868686868686868686868686868686868686868686868373768683636363636363636363668683737656565656565656565656565656565656565656565656565653434340a6665656565656565656565656565666665656534343434343434343434343737686868686868363636363636363636366868686868686868686868686868686868686868686868686868686868686868686868686868363636363636363636366868373765656565656565323232326565656565656565656565")
    (hex 65024 "6565653434340a65656565656565656565656565656565656565343434343434343434343437376868686868683636363636363636363668686868686868686868686868686868686868686868686868686868686868686868686868683636363636363636363668683737656565656565323232323232656565656565656565656565343434340a656565656565656565656565656565656565653434343434343434343434373768683636363636363636363636363636686836363636363668683636363636366868363636363636363636363636363668683636363636363636363636363636686837376565656565323232323232323265656565656565")
    (hex 65280 "65656565343434340a65656565656565656565656565656565656565653434343434343434343437376868363636363636363636363636363668683636363636366868363636363636686836363636363636363636363636366868363636363636363636363636363668683737656565653232323232323232323265656565656565656565343434340a65656565656565656565656565656565656565653434343434343434343437376868363636363636686868686868686868683636363636366868363636363636686836363636363668683636363636366868363636363636686868686868686868683737656565653232323232323232323265656565")
    (hex 65536 "656565656565343434340a65656565656565656565656565656565656565656534343434343434343437376868363636363636686868686868686868683636363636366868363636363636686836363636363668683636363636366868363636363636686868686868686868683737656565653232323232323232323265656565656565656565653434340a6565656565656565656565656565656565656565653434343434343434343737686836363636363668686868686868686868363636363636686836363636363668683636363636366868363636363636686836363636363636363636363636366868373765656565323232323232323232326565")
    (hex 65792 "6565656565656565653434340a65656565656565656565656565656565656565656565343434343434343437376868363636363636686868686868686868683636363636366868363636363636686836363636363668683636363636366868363636363636363636363636363668683737656565656532323232323232326565656565656565656565656534340a656565656565656565656565656868686865656565656534343434343434373768683636363636366868686868686868686836363636363668683636363636366868363636363636686836363636363668683636363636363636363636363636686837376565656565653232323232326565")
    (hex 66048 "65656565656565656565656565340a65656565656565656565656868686868686868656565656565343434343437376868363636363636686868686868686868683636363636366868363636363636686836363636363668683636363636366868363636363636363636363636363668683737343434656565653232323265656565656565656565656565656565650a65656565656565656565686868686868686868686565656565656534343437376868363636363636686836363636363668683636363636366868363636363636686836363636363668683636363636366868363636363636363636363636363668683737343434343434656565656565")
    (hex 66304 "656565656565656565656565656565650a65656565656565656568686868686868686868686865656565656565656537376868363636363636686836363636363668683636363636366868363636363636686836363636363668683636363636366868363636363636363636363636363668683737343434343434346565656565656565656565656565656565656565650a3232323265656565656868686868686868686868686565656565656565653737686836363636363668683636363636366868363636363636686836363636363668683636363636366868363636363636686868686868686868683636363636366868373734343434343434343465")
    (hex 66560 "6565656565656565656565656565656565650a32323232323232326868686868686868686868686868656565656565656537376868363636363636686836363636363668683636363636366868363636363636686836363636363668683636363636366868686868686868686836363636363668683737343434343434343434346565656565656565656565656565656565650a323232323232323268686868686868686868686868686565656565656565373768683636363636363636363636363636686836363636363636363636363636366868363636363636686836363636363668683636363636363636363636363636686837373434343434343434")
    (hex 66816 "34343465656565656565656565656565656565650a32323232323232326868686868686868686868686868656565656565656537376868363636363636363636363636363668683636363636363636363636363636686836363636363668683636363636366868363636363636363636363636363668683737343434343434343434343465656568686868656565656565656565650a32323232323232326868686868686868686868686868656565656565656537376868363636363636363636363636363668686868686836363636363636363636686836363636363668683636363636366868363636363636363636366868686868683737323434343434")
    (hex 67072 "343434343434686868686868686865656565656565650a32323232323232323268686868686868686868686865656565656565656537376868363636363636363636363636363668686868686836363636363636363636686836363636363668683636363636366868363636363636363636366868686868683737323232343434343434343468686868686868686868656565656565650a3232323232323232326868686868686868686868686565656565656565653737686836363636363636363636363636366868686868683636363636363636363668683636363636366868363636363636686836363636363636363636686868686868373732323232")
    (hex 67328 "3434343434346868686868686868686868686565656565650a32323232323232323232686868686868686868686565656565656565656537376868363636363636363636363636363668686868686836363636363636363636686836363636363668683636363636366868363636363636363636366868686868683737323232323434343434346868686868686868686868683465656565650a323232323232323232323268686868686868683434656565656565656565373768686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686837373232")
    (hex 67584 "32323234343434686868686868686868686868686834346565650a32323232323232323232323232686868683232323434656565656565656537376868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868683737323232323234343434686868686868686868686868686834343434650a32323232323232323232323232323232323232323434656565656565656537376868686868686868686868686868686868683737686868686868686868686868686868686868686868686868686868686868686868686868686868686868373737373737")
    (hex 67840 "323232323232343434686868686868686868686868686834343434340a32323232323232323232323232323232323232323234346565656565656537376868686868686868686868686868686868683737686868686868686868686868686868686868686868686868686868686868686868686868686868686868373737373737323232323232343434686868686868686868686868686834343434340a3232323232323232323232323232323232323232323234656565656565653737686868686868686868686868686868686868373768686868686868686868686868686868686868686868686868686868686868686868686868686868686837373232")
    (hex 68096 "3232323232323232343434346868686868686868686868683434343434340a32323232323232323232323232323232323232323232323465656565656537376868686868686868686868686868686868683737686868686868686868686868686868686868686868686868686868686868686868686868686868686868373732323232323232323232343434346868686868686868686868683434343434340a323232323232323232323232323232323232323232323234656565343434373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737")
    (hex 68352 "32323232323232323234343434343468686868686868686868343434343434340a32323232323232323232323232323232323232323232323265343434343437373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373732323232323232323234343434343434686868686868686834343434343434340a32323232323232323232323232323232323232323232323234343434343432323232323232323232323232323434343434343434343434323232323232323232323232323232323232323234343434343434343434343434343432323232")
    (hex 68608 "323232323232323232323434343434343434343468686868343434343434343434340a32323232323232323232323232323232323232323232323232343434323232323232323232323232323232323232343434343434323232323232323232323232323232323232323232323234343434343434343434343434343432323232323232323232323232323434343434343434343434343434343434343434343434340a3232323232326868686868686868683232323232323232323234343232323232323232323232323232323232323232343434343232323232323232323232323232323232323232323232343434343434343434343434343434343432")
    (hex 68864 "3232323232323232323232343434343434343434343434343434343434343434343434340a32326868686868686868686868686868686868323232323232323232323232323232323232323232323232323232323234343232323232323232323232326868686868686868683232323434343434343434343434343434343434343432323232323232323434343434343434343434343434343434343434343434343434340a686868686868686868686868686868686868686868323232323232323232323232323232323232323232323232323232323232323232323232323268686868686868686868686868686834343434343434343434343434343434")
    (hex 69120 "34343434343232323234343434343434343434343434343434343434343434343232323232320a68686868686868686868686868686868686868686868683232323232323232323232323232323232323232323232323232323232323232323268686868686868686868686868686868686868343434343434343434343434343434343434343434343434343434343434343434343434343434343434343232323232323232320a68686868686868686868686868686868686868686868686868323232323232323232323232323232323232323232323232323232323232686868686868686868686868686868686868686868686834343434343434343434")
    (hex 69376 "343434343434343434343434343434343434343434343434343434343432323232323232323232320a68686868686868686868686868686868686868686868686868683232323232323232323232323232323232323232323232323232323268686868686868686868686868686868686868686868686868343434343434343434343434343434343434343434343434343434343434343434343434343232323232323232323232320a6868686868686868686868686868686868686868686868686868683232323232323232323232323232323232323232323232323232686868686868686868686868686868686868686868686868686868343434343434")
    (hex 69632 "3434343434343434343434343434343434343434343434343434343432323232323232323232323232320a68686868686868686868686868686868686868686868686868686868323232323232323268686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686834343434343434343434343434343434343434343232323232323232323232323232320a686868686868686868686868686868686868686868686868686868686832323232323232683232323232323232323232323232686868686868686868686868686868686868686868686868686868686868683232")
    (hex 69888 "34343434343434346834343434343434343434343434343434343434323232323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686832323232323268326868686868686868323232323232323232686868686868686868686868686868686868683232323232323232686868686868686868346834343434343434346868686868683434343432323232323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868323232323268326868686868686868323232323232323232686868686868686868686868686868686868683232323232323232")
    (hex 70144 "686868326565326868346834343434343468686868686868686868343432323232323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868683232323268326868356464356868323232323232323232686868686868686868686868323838383268683232323232323232686865656565653268346834343434686868686868686868686868686832323232323232323232323232323232320a6868686868686868686868686868686868686868686868686868686868686868323232326832683764646464356832323235333335323268686868686868686868683238383838383268323232323232")
    (hex 70400 "6830683265656566666568346834343468686868686868686868686868686868323232323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868686832323268323535376432326468323233333333333961686868686868686868686838323238383838683932323232683030686565686566306568346834346868686868686868686868686868686868683232323232323232323232323232320a686868686868686868686868686868686868686868686868686868686868686868323232683268353764383832353235333333336161616868686868686868686868323637383836366861613932")
    (hex 70656 "30303961686565686565376568346834346868686868686868686868686868686868683232323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868686868323268326868643868383864323333333339616132686868686868686868686836373732363636686161616161306363686532683237663768346834686868686868686868686868686868686868686832323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868686868323268326868643868383864323330303361343432686868323432686868686837373036366868683961")
    (hex 70912 "616130636863686565686866666668346834686868686868686868686868686868686868686832323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868686868683268326835646438386464683330683339343434683939343434326868686837363035363636683939616130636863686565326830306668346868686868686868686868686868686868686868686868323232323232323232323232320a6868686868686868686868686868686868686868686868686868686868686868686868326832353364646464643568353333333339393468613934683432326868683630303036363668")
    (hex 71168 "6539393039616363683265653030306868346868686868686868686868686868686868686868686868323232323232323232323232320a68686868686868686868686868686868686868686868686868686868686868686868683268683333643364646468683235333333333339686861373432323232686836683030363638683865303061616137686865653030686868326868686868686868686868686868686868686868686868323232323232686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686833323333643335686832323333333333326868363737373232326868686832383838")
    (hex 71424 "38683238303737373737686832656532686868326868686868686868686868686868686868686868686868323232686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683232323333333368683232353333333732686868363737373668686868323838383832683235373737373737686568686565326868686868686868686868686868686868686868686868686868326868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683232323232333232683236353537373434683468686568656868686839323838")
    (hex 71680 "383238683237373737373737686565683265656868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683632363236323236686436366435353434683234656868656868686161383838396138683035373737373737686565326865653268686868686868686868686868686868686868686868686868686868686868686868686868680a6868686868686868686868686868686868686868686868686868686868686868686868686868363636363632363668363636363664643568683232346534326868636361")
    (hex 71936 "3838636161683030303537373737686565656832656568686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686835353535353535356834343434343434346835353535353535356832")
    (hex 72192 "32323232323232683434343434343434683535353535353238686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683535353535353535683434343434343434683535353535353535683232323232323232686364343434343434683535353532383838686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683535363737363535683434343436373736683535356565653535")
    (hex 72448 "683232323232326830686363636434343434683535353238383838686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683537373737373735683434343637373737683565666666666632683232323232303030683763636364343434683535643838386537686868686868686868686868686868686868686868686868686868686868686868686868680a6868686868686868686868686868686868686868686868686868686868686868686868686868643637373736366468343437373737646468326666666666")
    (hex 72704 "3232683232326830303030686337376363643434683535363637373737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686464643737646464683434373737643036683232666632323035683268303030303030683730646368686834683536363737373737686868686868686868686868686868686868686868686868686868686868686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686839303037373030396834343637373630366835303238")
    (hex 72960 "65303035683439393934303030683730306330686868683568306161373737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683739303961303937683434343937373636683566383838386665683268683039393930683737376363303434686430613232613730686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683737373939373737683434393961613737686638")
    (hex 73216 "323838323866683232323261303030686837373737363434683637613268686130686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683637393961393737683439396137373737686632653232653266683232323261396830686868373737363434683637396868393937686868686868686868686868686868686868686868686868686868686868686868686868680a6868686868686868686868686868686868686868686868686868686868686868686868686868303768396168363768343961343737373768")
    (hex 73472 "6666666565666665683232323237616139686368373737343434683637383939393737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683036303061306837683434343437373737683566656565666635683232323237373761686363683736343434683737383838383737686868686868686868686868686868686868686868686868686868686868686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686830683030393030366834343464373737")
    (hex 73728 "37683566656565653235683232323637373737686364376834343434683737653838383737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868683030303030306830686436363636373737683535326565653235683232323637373737686437373634343434683737373838653737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686830303030306830683636363636")
    (hex 73984 "363737683535356565656532683232323737373737683737373434343434683737373737373737686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686830306830303030683636363636363636683535353265656565683232323737373737683737363434343434683737373737373737686868686868686868686868686868686868686868686868686868686868686868686868680a6868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 74240 "6868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 74496 "68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 74752 "686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a6868686868686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 75008 "6868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a686868686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 75264 "68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868")
    (hex 75520 "686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a68686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868686868680a0a5f5f6766665f5f0a3030303030343034303030343031303030343034303330343031303130")
    (hex 75776 "31303130383030303030313033303330303131303430333033303431313033303130313033306230623062303130313031303430313031303130313031303330313034303330623062306230313031303130303034313130313031303130333031303430303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030")
    (hex 76032 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6d61705f5f0a33393339333933393339333933393339333933")
    (hex 76288 "3933393339333933393339333931633163316330343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343163316331633163316331633163316331633163316331633163316331633163316331633339333933393030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a306332383238323832383238323932393238")
    (hex 76544 "323932393063333933393339333930343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306333393339333933393339333933393339333933393339333933393339306332383238323932383238323832393238323832383239323832383238323932383063323832393238306332383238323832383238323832383238306332383238323832383238323832383238323832383238323832383238323832383238323830633238323932393239323932393063333933393339333933393339333933390a3064323132373237323732373237323732")
    (hex 76800 "37323732373238323932393063333930343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303733393339333933393339333933393339303730373037306433313064303830383038306230383038303830383062303830383038306432663064323432353236306432313231323732373237323132323233306432373266323033313237323732373237323732373237323133313231323732373331333030643237323732373237323732373238323932393063333933393339333933390a30643231323732373237323732373237")
    (hex 77056 "3237323732373266323732373238313330343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432303066303830383038316230383038303830383162303830383038306632663064333433353336306432313237323732373237333133323333306432373266326332643265323732633164326532373263326432653237326331643265323130643237323732373237323732373237323732373238323930633339333933390a306432373237323732373237323732")
    (hex 77312 "373237323732373266323732373366313330343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432373166303830383038303830383062306230383038303830383038316632663064323732373237306432373237306332373237323732323233306432373266336333643365323733633364336532373363336433653237336333643365326630643237323732373237323732373237323732373237323732383133333933390a3036323732373237323732373237")
    (hex 77568 "32373237323732373266323732373237313330343030303030303030303030303030323130303030303030303030303030343034303030303030303032313231323130303030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432373161303930383038303830383162316230383038303830383039316132663064323732373237306432373237306432373237323732313333306432373266323732373237323732373237323732373237323732373237323732373237316130643237323732373237323732373237323732373237323732373133316331630a30363237323732373237323732")
    (hex 77824 "3732373237323732373266323732373366313330343030303030303030303030303231323130303030303030303030303030343034303030303030323130303030303032313030303030303030303030303034323830373037303730373339333933393339333933393037303730373037323832373237323730393039303930393039303930393039303930393237323732663238323832383134306432373237306432373237323732313231306432373266303530353035303530353035303530353035303530353035303530353035303530363237323732373237323732373237323732373237323732373133333933390a303632373237323732373237")
    (hex 78080 "323732373237323732373266323732373237313330343030303030303030303032313030323130303030303030303030303030343034303030303030303030303030323130303030303030303030303030303034323730373037303730383038303830383038303830383038303730373037323732373237323732373237323732373237323732373237323732373237323732663237323732373237323831343134323832383238306332383238323832373266303230323032303230323032303230323032303230323032303230323032303230363237323732373237323732373237323732373237323732373133333933390a3036323732373237323732")
    (hex 78336 "37323732373237323732373266323732373366313330343030303030303030303030303030323130303030303030303030303030343034303030303030303030303231303030303030303030303030303030303034306330373037303730373339333933393339333933393037303730373037306332373237326332373164323732653237323732633237316432373265323732663237323732373237323732373237323732373231306432323233323732373266303330333033303330333033303330333033303330333033303330333033303330363237323732373237323732373237323732373237323732373133333933390a30363237323732373237")
    (hex 78592 "3237323732373237323732373266323732373237313330343030303030303030303032313231323132313231303030303030303030343034303030303030323132313231323132313030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432373237336332373364323733653237323733633237336432373365323732663237323732373237323732373237323732373237306633323333323732373266323732373237323732373237323732373237323732373237323732373237316130633237323732373237323732373237323732373237323732373133333933390a306432373237323732")
    (hex 78848 "373237323732373237323732373266323732373366313330343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432373237323732373237323732373237323732373237323732373237323732663237323732373237306331613237323732373237316632373237323732373266326331643265323732633164326532373263326432653237326331643265326630643237323732373237323732373237323732373237323730633133333933390a3064323132373237")
    (hex 79104 "32373237323732373237323732373266323732373063313330343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303730373339333933393339333933393037303730373037306432373237323732373237323732373237323732373237323732373237323732663237323732323233306432373237323732373237323132373237323732373266336333643365323733633364336532373363336433653237336333643365323030643237323732373237323732373237323732373063323932383339333933390a30643231323732")
    (hex 79360 "3732373237323732373237323732373063323832383238333930343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034306430373037303731373339333933393339333933393137303730373037306432373237323732633237316432373265326332373164323732653237323732663237323732313333306432373237323732373237323732373237323732373266323732373237323732373231333133313237323732373237323732373331333030643237323732373237323732373063323932393238333933393339333933390a323832383238")
    (hex 79616 "323832383238323932393238323932393238333933393339333930343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034323831373137313733393339333933393339333933393339313731373137323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932393239323932393238333933393339333933393339333933390a3339333933")
    (hex 79872 "39333933393339333933393339333933393339333933393339333930343030303030303030303030303030303030303030303030303030303030343034303030303030303030303030303030303030303030303030303030303034333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933390a31633163")
    (hex 80128 "3163316331633163316331633163316331633163316331633163316330343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034303430343034333933393339333933393339333933393339333933393339333933393339316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331630a313333")
    (hex 80384 "393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333930303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3063")
    (hex 80640 "33393339333933393339333933393339333933393339333933393339306330633238323932383238323832393238323832383239323832383238323932383238323832393238306332383239323832383063323932383238323832393238323832383239323832383238323932383238323832393238323832383239323830633238323932383238323832393238306332383239323832383238323932383238306332393238323832383239323832383238323932383238323832393063323832383063323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932380a30")
    (hex 80896 "6430373037303733393339333933393339333933393339303730373037306430643231323232333237323132313231333133313331333133313231323732373237323733313231306430383062303830383064323132313237323732373237316132373161323732373161326432373163323132313161323732373161323730643231323132313231323133313231306432633264326532373263326432653237306430623038323732373237323733643164323732373237323732653064323132373064323132313331323732373237323732373331333132373237323732373237323732313231323732373231323132373237323132313237323732370a")
    (hex 81152 "30643037303730373037333933393339333933393339303730373037303730643064323133323333323132313331323733313231323132373231333132373231323732373237323730663038316230383038306632373237323732373237323732373237323732373364323731643237323732373237323732373237323732373064323133313331366432313231323130643363336433653237336333643365323730643162303830383237323732373237326432373237323732373365306433313237306432313237323731613161323732373237323732373237323732373237323732653063323832383239323832383239323832383063326332373237")
    (hex 81408 "0a306430373037303730373034303430343034303430343037303730373037306430643231333133303331323732373237323732373331323732373331323132373237323732373161316630393039303930393166316132373237323732373237323732373237323732373237313930613061306130613061316332373237323732383238323832383134323832383238306432373237323732373237323732373237306430383038323732373237323733643164323732373237323732313064333132373064323732373237316131613237316132373237323732373237323732373237336530643331323732373664323736643331333132383363323732")
    (hex 81664 "370a3064303730373037303731633163316331633163316330373037303730373064306432363336323132373237323732373237323732373237323732373331323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373064323732373237323732373237323732373238323832383063323732373063323832383063323831343134323832383237323730643237316132373161316136643161323732373065323732373237323732373237306432373237323732373237323732373237323732373237")
    (hex 81920 "32370a30643037303730373037333933393339333933393339303730373037303732383064323632303237323732373237323732373237323732373237333132313231323732633264326532373237323732373664323732633164326532373237323732373237326332643265323732373364323732373237336432373237323732373237323732373237323732373237323730643237323732373237323732643237323732373237323730643237323730643237323730643161323732373237323732373237306432373161323731613161316131613237323730643237323732373237323733643064323732373237323732373664323732373063323732")
    (hex 82176 "3732370a303630373037303730373034303432373237303430343037303730373037323730643234323532373237323731363237323732373237323732373237323132373237336333643365323732373237323732373237336333643365323732373237323732373363336433653237323732373664323736643237323732373237323732373263326432653237326332643265306632633264326532373237326432373237323732373237323831343134323832373237306432373237323732373237323732373064323731613161316131613164366432373237306432373237323732373237323732383237326332373261326232373265323730643364")
    (hex 82432 "323732370a3063303730373037303733393339313731373339333930373037303730373063306433343335323732373237323732373237323732373237323732373331323732373237323732373237323736643237323732373237323732373237323732373237323732373237323732373237323732373237323732633264326532373237323733633364336532373363336433653166336333643365323732373264323732373065323732373161323732373161323732373064333032363234323532373237323730643237323731643161316132643237323732373064323732373237323732373237323732373363323733613362323733653237306432")
    (hex 82688 "37323732370a30643037303730373037333933393339333933393339303730373037303730643064333032363331323732373237323732373237323732373331323732313331323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237336333643365323732373237323732373237323732373237323732373237323732373237366433643237323730643237323732373237323732373237323730643236333633343335323732373237306632373237313930613061313532373237323730643237323732373237323732653063323732373237323732373237323732373064")
    (hex 82944 "3263323732370a306430373037303730373034303430343034303430343037303730373037306430643230333032313237323732373237323732373237323732373231323132373237323732373263326432653237323732633264326532373237323732373237323733643237323733643237323733643237323732373237323732373237323732373237323732373237323732373237323732373237323732373237323732373237306432373237323736643237366432373237306431613237323732373237323732373166323732373364336433643364323732373231306432313237323732373237336530643237323732373237323732373237323730")
    (hex 83200 "643363323732370a3064303730373037303733393339333933393339333930373037303730373064306433363230323032303234323532363237323232333231323133313237323732373237323733633364336532373237336333643365323732373237323732373231306130613061306130613061306130613061323732373237323732373237323732633264326532373263326432653237306130613061306130613061306132373064333132373237323732373237323733303064326332373237323732373237323732373237323732373237323732373237323732313064323132373237323732373237323832383238323932383238323932383238")
    (hex 83456 "32383237323732370a30643037303730373137333933393339333933393339313730373037303730643064333633363230323633343335333633363332333332313231323632363237323732373237323732373237323732373237323732373237323732373237323732313237323732373237323732373237323732313237323732373237323732373237336333643365323733633364336532373231323732373231323732373231323730643236323132313237323732373331323030643363323732373237323732373237323732373237323732373237323732373237323130643231323732373237323732373231323132373237323132313237323732")
    (hex 83712 "3132313237323732370a323831373137313733393339333933393339333933393339313731373137323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239323832383238323932383238323832393238323832383239")
    (hex 83968 "323832383238323932380a3339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933393339333933")
    (hex 84224 "39333933393339333933390a31633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163316331633163")
    (hex 84480 "3163316331633163316331630a5f5f7366785f5f0a3065303430343038306334373030633137303063313730306331373030633137303063313730306331373030633137303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130300a303130633030303030633835303062383331306138313131383835303030383030303038303031363835303030383030303030353030303030303030303530303030")
    (hex 84736 "3030303030353030303030303030303530303030303030633835303062383331306138313131383835303030383030313838353031363835303030303030306330353030303030303030303530303030303030633035303030303030303030353030303030300a303330633030303032343633353138303030336336333033633632303234363335313830303033633633303363363230323436333531383030303363363330336336323032343633353138303030336336333033633632303234363335313830303033633633303363363230323436333531383030303363363330336336323032343633353363363535336336333533633632353363363335")
    (hex 84992 "3363363535336336333533633632350a3031306330303030306338353030623833313061383131313838353030303830303030383030313638353030303030303032303530303039303030653035303063393030303230353030303030303065303530303030303030663835303065383331306438313131623835303030383030303038303031613835303030303030303530353030303030303131303530303030303030353035303030303030313130353030303030300a3031306330303030323435353032343533303234353130306335303030633530303063353030323335353032343535303236353530323635333032363531303063353030306335")
    (hex 85248 "303030633530303234353530323635353032373535303237353330323735313030633530303063353030306335303032363535303234353530323235353032323533303232353130323935353432393535353063353030333035353433303535350a3031306330303030326235353432623535323262353432326235333232623532323262353135306335303230633530323063353032306335303230633530323063353032306335303230633530303262353234323935353532373535353063353032306335303230633530323063353030306335303030633530303063353030323635353432363535353063353030323735353432373535353063353030")
    (hex 85504 "323635353432363535350a3031306330303030323435353032343533303234353130306335303030633530303063353030323335353032343535303236353530323635333032363531303063353030306335303030633530303234353530323635353032373535303237353330323735313030633530303063353030306335303032363535303237353530323935353032393533303239353130323735353432373535353063353030323935353432393535350a30313063303030303262353534326235353232623534323262353332326235323232623531353262353534306335303232623535343063353034326235353430633530343262353534306335")
    (hex 85760 "30343262353534303030303432623535343030303034326235353430303030343262353534303030303432623535343030303034326235353430303030343030303034303030303432663535343030303034333035353433303535320a30313063303030303234353534323435353232343534323234353332323435323232343531353234353534306335303232343535343063353034323435353430633530343234353534306335303432343535343030353034323335353430303530343233353534303035303432333535343030353034323335353430303530343233353534303035303430303530343030353034326235353430303530343262353534")
    (hex 86016 "32623535320a3031306330303030306338353030303830303063383530313838353030303830303138383530313638353030303830303063383530303038303030633835303138383530303038303031383835303136383530303038303030613835303030383030306138353031363835303030383030313638353031343835303030383030306138353030303830303061383530313638353030303830303136383530313438353030303030300a303130633030303033303535323330353432326635333132653532313264353131326335313130303030303030303030323435353232343535353030303030333035353233303535353030303030326535")
    (hex 86272 "3534326535353232653535323265353432326435333132633532313262353131326135313130303030303030303030323235353232323535353030303030326535353232653535353030303030326335353432633535320a303130633030303032623535323262353432326135333132393532313238353131323735313130303030303030303030316635353231663535353030303030326235353232623535353030303030323935353432393535323239353532323935343232383533313237353231323635313132353531313030303030303030303031643535323164353535303030303032393535323239353535303030303032373535343237353532")
    (hex 86528 "0a3031306330303030303838353030303830303038383530313438353030303830303134383530313338353030303830303038383530303038303030383835303134383530303038303031343835303133383530303038303030373835303030383030303738353030303830303037383530303038303030373835303030383030303738353030303830303062383530303038303030653835303030383030313138353030303030300a3031306330303030326335353232633534323262353331326135323132393531313238353131303030303030303030303230353532323035353530303030303263353532326335353530303030303262353534326235")
    (hex 86784 "353232623535323262353235326335353432633535303262353530326235323532633535303263353235326235353032623532353030303030326230303032663535313266353535333035353433303535320a3031306330303030323735353232373534323236353331323535323132343531313233353131303030303030303030303162353532316235353530303030303237353532323735353530303030303236353534323635353232363535323236353235323735353432373535303236353530323635323532373535303237353235323635353032363532353030303030326230303032623535313262353535326235353432623535320a30313063")
    (hex 87040 "30303030303838353030303830303038383530313438353030303830303134383530313338353030303830303038383530303038303030383835303134383530303038303031343835303136383530303038303030613835303030383030306138353031363835303030383030313638353031343835303030383030306138353030303830303061383530313638353030303830303136383530313738353030303030300a30313063303030303263353532326335343232623533313261353231323935313132383531313030303030303030303032303535323230353535303030303032633535323263353535303030303032653535343265353532326535")
    (hex 87296 "35323265353235303030303030303030303030303030303030303030303030303030303030326235353232623535353030303030326635353232663535353030303030333535353233353535350a3031306330303030323735353232373534323236353331323535323132343531313233353131303030303030303030303162353532316235353530303030303237353532323735353530303030303239353534323935353232393535323239353235303030303030303030303030303030303030303030303030303030303030323635353232363535353030303030326235353232623535353030303030326635353232663535350a303130633030303030")
    (hex 87552 "6338353030303830303063383530313838353030633830303138383530306338353030303830303062383530303038303030623835303137383530306238303031373835303062383530303038303030613835303030383030306138353031363835303061383030313638353030613835303030383030303938353030313830303039383530313538353030393830303135383530303938353030313830300a303530633030303033333735323333373432333237333133313732313330373131326637313133323735323332373535333337353233333735353332373532333237353533333735323333373535333237353233323735313333373531333337")
    (hex 87808 "3535333237353233323735353330373532333037353532623735343262373532326237333232623732323262373135303037303030303730303030373030303037303030303730300a3039306330303030333037353233303734323266373331326537323132643731313263373131326237353232623735353262373532326237353532623735323262373535326237353232623735353262373532326237353132623735313262373535326237353232623735353262373532326237353532373735343237373532323737333232373732323237373135303037303030303730303030373030303037303030303730300a3031306330303030303838353030")
    (hex 88064 "303830303038383530313438353030383830303134383530303838353030303830303037383530303038303030373835303133383530303738303031333835303037383530303038303030653835303032383030306538353031613835303065383030316138353030653835303032383030306338353030303830303063383530313738353030623830303137383530306238353030303030300a3033306330303030323436333531383030303363363330336336323032343633353138303030336336333033633632303234363335313830303033633633303363363230323436333531383030303363363330336336323533633630303030303030336336")
    (hex 88320 "333033633632353030303030303030303033633633303363363235336336333533633635353234363335323436323533633635353363363535323436353532343635350a3035306330303030333337353233333734323332373331333137323133303731313266373131333237353233323735353333373532333337353533323735323332373535333337353233333735313335373531333537333233353732323335373135333337353433333733323333373232333337313533323735343332373332333237323233323731353333373534333337333233333732323333373135303037303030303730300a30393063303030303330373532333037343232")
    (hex 88576 "66373331326537323132643731313263373131326237353232623735353263373532326337353532623735323262373535326337353232633735313332373531333237333233323732323332373135333037353433303733323330373232333037313532663735343266373332326637323232663731353330373534333037333233303732323330373135303037303030303730300a30313063303030303038383530303038303030383835303134383530303838303031343835303038383530303038303030383835303031383030303838353031343835303035383030313438353030383835303031383030306138353030303830303061383530313638")
    (hex 88832 "35303063383030313638353030613835303030383030306138353030613835303063383030313338353031333835303137383030313738353031373835300a3035306330303030326337353232633734323262373331326137323132393731313238373131303037303030303730303230373532323037353530303730303263373532326337353530303730303265373534326537353232653735323265373235303037303030303730303030373030303037303030303730303030373030326237353232623735353030373030326637353232663735353030373030333537353233353735350a303930633030303032373735323237373432323437353032")
    (hex 89088 "3437353031663735303166373530323437353032343735303237373532323737353530303730303237373532323737353530303730303236373534323637353232363735323236373235303037303030303730303030373030303037303030303730303030373030323337353232333735353030373030316637353231663735353030373030316137353231613735350a303130633030303030633835303063383030306338353030633830303063383530306338303030633835303063383030306338353030633831303063383530306338313030633835303063383130306338353030633831303063383530306338333030633835303063383330306338")
    (hex 89344 "3530306338333030633835303063383330306138353030613832303030383030306138353030613832303030383030306338353030633832300a3033306330303030323436333031383030303363363330336336323032343633353138303030336336333033633632303234363335313830303033633633303363363230323436333531383030303363363330336336323032343633353138303030336336333033633632303234363335313830303033633633303363363230323436333530303030303030303030323436333530303030303030303030336336333033633632350a3039306330303030303035303030303530303030353030303035303030")
    (hex 89600 "303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030326535353032653532323030353030326535353032653532323030353030333035353033303532320a3039306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 89856 "303030303030303236373530323637323030303030303236373530323637323030303030303237373530323737323530303030300a3030303230303030303832373030623337303066343730313336373032373637303035323630306636363030623335303135363530306536353330343234333064363433303336333330383632333030363133303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303032303030303061343730306636373031653637303032323630306436353030")
    (hex 90112 "34343430303736323030303432303032363230306536303330343230333064363033303336303330383630333030363033303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303036303030303237323530316332353031343235303162323530313532353030653235303130323530303832353030343235303032323530303132353030303235303030323530303032353030303235303030323430303032343030303233303030323330303032323030303231303030323130303032")
    (hex 90368 "30303030323030303032303030303230303030323030303032303030303230303030323030303032303033653230300a3030303330303030313932353031333235303066323530306232353030373235303034323530303232353030313234303030323430303032343030303234303030323330303032323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030313030303032323635303135363030336536353030343035303066363530306230333030")
    (hex 90624 "3736313030343630303034363030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030323030303030623537373132313731336436373230303437363164363734303032373730313737333163363636303131363232323635303031373435313936343630313233303231363335303136333732313633363163363334303134333031393632373030323236316236323230653631313066363135303032")
    (hex 90880 "3136303336313230323631333063323034303633303730323530323032363033306134303630353730340a3030303330303030316535353032303735303233353530323337353030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530300a3030303130303030306331353531353030333030303030303030303030303030303030303030303030303030")
    (hex 91136 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030313030303030313131353031303135303066313530306131353030393135303038313530303231353030313135303030313530303031353030303134303030313430303031323030303131303030313030303031303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 91392 "303030303030303030303030303030303030303030303030303030303030303030303030300a3031303430303030316630353032363035303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303036303030303138303530316330353031663035303234303532323430303032343030303030303030303030303030")
    (hex 91648 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303034303030303065353530306235303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035")
    (hex 91904 "30303030353030303035303030303530303030353030303035303030303530300a3030303430303030336330303032623135303264313630323531333031623135303134313530313531353031393135303162313530316630303031653030303230303030303030303032383030303262303030326130303032633030303266303030333330303033373230303263323030303132303030343230303030323030303032303030313230303364323030333832303033313230303261323030323732303032623730300a316230373030303032663235303231323530323732353031623235303232323530313232353031613234303063323430313432343030")
    (hex 92160 "3632343030643233303031323330303632333030303233303030323330303032303030373635303030323030303336353030303230303032363530303032303030373635303030323030303236353030303230303030323030306336353030303230303035363530303136353030303230300a303030333030303031643035303232303530303530303030353030303034303030303330303030333030303364303030323330303031643030303138303030323630303030643030303063303030313730303031323030303131303030326130303033333030303333303030313530303032383030303162303030333730303031663030303161303030313730")
    (hex 92416 "3030323330303031303030303164303030313730303031383030300a3030303230303030316336353031373630303135363030313336303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303930303030306235373331323137313364363732303034373631643637343030323737303137373331633636363031313632323236353030")
    (hex 92672 "313734353139363436303132333032313633353031363337323136333631633633343031343330313936323730303232363162363233306536313330663631333030323133303336313330323630333037323033303436303330363230333034363033303632303330343630330a3039306330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030323637353032363732303030303030323637")
    (hex 92928 "353032363732303030303030323737353032373732350a3930303230303030303536303230343630323036363032303536303230363630323033363032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030320a39303032303030303035363432303436313230363633323035363232303636323230333632323030303032303030303230303030323030303032303030303230")
    (hex 93184 "30303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030323030303032303030303230303030320a30303032303030303038323730333432373030663437303033353730323736373030343536303066363630326532353031353635303065363533303335343330643634333033363333323632323330303631333030353230323334303032313430303230323230316634303031653430303063323130326333303032633330303030303030303030303030303030303030303030303030")
    (hex 93440 "30303030303030303030303030303030300a3030303130303030313231363030613136303034343630303434363030343436303136363530303334353030333434303032343430303936343030333434303031343530303134353030313435303033343030313434303030333430303062343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430303030343030303034303030303430300a5f5f6d757369635f5f0a30302030313032333233320a30302030313032333233320a30312030333032303433320a30302030313032303533320a3030203033303230363332")
    (hex 93696 "0a30302030333032303730380a30302030393032306130620a30302030633032306430650a30302030393032306130620a30302030663032313031310a30302030393032306130620a30302030633032306430650a30302030393032306130620a30302030663032313031310a30302031323032313331340a30302031353136313731380a30302031323032313331340a30322031393032316131620a30302034313432343334340a30302034313432343334340a30302034313432343334340a30302034313432343334340a30302034313432343334340a30342031633164316533310a30312030313432343334340a30322030333432343334340a303020")
    (hex 93952 "34313432343334340a30302034313432343334340a30302034313432343334340a30302034313432343334340a30302034313432343334340a30302034313432343334340a30312032353261343334340a30322035663432343334340a0a")))
