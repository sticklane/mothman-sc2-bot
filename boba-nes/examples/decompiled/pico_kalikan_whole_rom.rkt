#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : PICO Night Punkin (pico_night_punkin.p8)
;; Source ROM : assets/roms/pico/pico_night_punkin.p8 (44693 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "kalikan")
  (title "PICO Night Punkin (pico_night_punkin.p8)")
  (rom-source "pico/pico_night_punkin.p8")
  (rom-bytes 44693)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label sfx music))
    (lua-line-count 318)
    (lifted-function-count 14)
    (gfx-row-count 128)
    (map-row-count 0)
    (gff-row-count 0)
    (sfx-row-count 17)
    (music-row-count 11))
  ;; --- 2. Hardware Interrupt Vectors & Entry Points ---
  (interrupt-vectors
    (init-hook _init)
    (update-hook _update)
    (draw-hook _draw))
  ;; --- 3. Graded Coeffect-Effect Resource & Capability Summary ---
  (coeffect-grades
    (Phi1-frame-budget 32768)
    (Phi2-token-count 2993)
    (Phi2-token-budget 8192)
    (Phi3-sram-bytes 8192)
    (CapMem RamLinear))
  (hardware-capabilities
    (lifted-functions (_draw _init _update60 draw_girlfriend draw_logo fade0 fade1 get_splash_text menu_draw menu_init menu_update splash_draw splash_init splash_update))
    (pico8-api-calls (btnp ceil cls flr max music pal palt poke print rectfill rnd sfx sspr))
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 0)
    (active-sfx-lifted 17)
    (active-music-lifted 10))
  ;; --- 4. Symbolic MMIO Cross-Reference, Subroutines & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function
      (name _init)
      (params ())
      (line-range (4 18))
      (api-calls (flr music poke rnd))
      (called-functions (splash_init))
      (body-lines
        "function _init()"
        "\tpoke(0x5f2d,1)"
        "\tcartdata(\"ckcw_fnfp8\")"
        "\tstep = 0"
        "\tinc = 509/64--509/32"
        "\tlogo = 1"
        "\tmenustate = -1"
        "\tfade = 0"
        "\tfading = -1"
        "\tsplash_init()"
        "\tmusic(0)"
        "\tsynctime = 509"
        "\tdset(60,0)"
        "\tif(flr(rnd(100)) == 0) logo = 2"
        "end"))
    (def-pico-function
      (name _update60)
      (params ())
      (line-range (20 27))
      (api-calls (poke))
      (called-functions (menu_update splash_update))
      (body-lines
        "function _update60()"
        "\t--step = stat(26) + (stat(24)*  509)"
        "\tif(menustate == 0 or menustate == 1) menu_update()"
        "\tif(menustate == -1) splash_update()"
        "\tstep+=1"
        "\tpoke(0x5f30,1)"
        "\t--if(stat(26) > synctime) synctime = stat(26)"
        "end"))
    (def-pico-function
      (name _draw)
      (params ())
      (line-range (29 49))
      (api-calls (ceil cls max palt rectfill))
      (called-functions (fade0 fade1 menu_draw splash_draw))
      (body-lines
        "function _draw()"
        "\tcls()"
        "\tpalt(0,false)"
        "\tpalt(9,true)"
        "\trectfill(0,0,128,128,0)"
        "\tcolor(6)"
        "\tif(menustate == -1) splash_draw()"
        "\tif(menustate == 0 or menustate == 1) menu_draw()"
        "\tif fading > -1 then"
        "\t\tif(fading == 0) fade0(ceil(fade))"
        "\t\tif(fading == 1) fade1(ceil(fade))"
        "\t\tif(fading == 2) fade0(15-ceil(fade))"
        "\t\tif(fading == 3) fade1(15-ceil(fade))"
        "\t\tif(fade > 0) fade -= 0.5"
        "\t\tif fade == 0.5 and menustate == 0 and fading == 2 then"
        "\t\t\t--fade = 15"
        "\t\t\t--fading = 0"
        "\t\t\t--menustate = 1"
        "\t\t\tdset(59,max(0,stat(24)-2))"
        "\t\t\tload(\"#fnf_select\")"
        "\t\tend"))
    (def-pico-function
      (name menu_init)
      (params ())
      (line-range (62 68))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function menu_init()"
        "\tmenustate = 0"
        "\tstate = 0"
        "\tnextstate = -1"
        "\tstarting = -1"
        "\tloading = false"
        "end"))
    (def-pico-function
      (name menu_update)
      (params ())
      (line-range (70 77))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function menu_update()"
        "\tif nextstate > 0 then"
        "\t\tnextstate -= 1"
        "\t\tif nextstate == 0 then"
        "\t\t\tfading = 2"
        "\t\t\tfade = 15"
        "\t\t\tnextstate = 0"
        "\t\tend"))
    (def-pico-function
      (name menu_draw)
      (params ())
      (line-range (98 104))
      (api-calls (pal rectfill))
      (called-functions ())
      (body-lines
        "function menu_draw()"
        "\tif menustate == 0 then"
        "\t\trectfill(0,0,128,128,0)"
        "\t\t--girlfriend outline"
        "\t\tfor i=0,15 do"
        "\t\t\tpal(i,12)"
        "\t\tend"))
    (def-pico-function
      (name splash_init)
      (params ())
      (line-range (135 139))
      (api-calls (flr rnd))
      (called-functions (get_splash_text))
      (body-lines
        "function splash_init()"
        "\tsplashstate = 0"
        "\tsplashtext = get_splash_text()"
        "\tispresident = flr(rnd(100)) == 0"
        "end"))
    (def-pico-function
      (name splash_update)
      (params ())
      (line-range (141 148))
      (api-calls (btnp poke))
      (called-functions (menu_init))
      (body-lines
        "function splash_update()"
        "\tif btnp() == 64 then"
        "\t\tsplashstate = 0"
        "\t\tmenu_init()"
        "\t\tfading = 1"
        "\t\tfade = 15"
        "\t\tpoke(0x5f30,1)"
        "\tend"))
    (def-pico-function
      (name splash_draw)
      (params ())
      (line-range (175 187))
      (api-calls (print))
      (called-functions ())
      (body-lines
        "function splash_draw()"
        "\t--print(splashtext[1],63,63)"
        "\tlocal _tx = \"\""
        "\tif splashstate == 0 or splashstate == 1 then"
        "\t\t_tx = \"cARSON kOMPON\""
        "\t\tprint(_tx,64-#_tx*2,54)"
        "\t\t_tx = \"& cHRIS wEST\""
        "\t\tprint(_tx,64-#_tx*2,60)"
        "\t\tif splashstate == 1 then"
        "\t\t\t_tx = \"present\""
        "\t\t\tif(ispresident) _tx = \"& tHE pRESIDENT\""
        "\t\t\tprint(_tx,64-#_tx*2,66)"
        "\t\tend"))
    (def-pico-function
      (name get_splash_text)
      (params ())
      (line-range (227 231))
      (api-calls (flr rnd))
      (called-functions ())
      (body-lines
        "function get_splash_text()"
        "\tlocal _splashs = \"SHOUTOUTS TO TOM FULP:LMAO|DA BABY:BIGGEST INSPIRATION|THIS GAME IS DEDICATED TO RINGO:MY FAVORITE BEATLE|THAT'S A HEALTHY LOOKING PENIS:THAT'S AN AMERICAN PENIS|pico-8 EXCLUSIVE:SPLASH TEST|REFINED TASTE IN MUSIC:IF I SAY SO MYSELF|SWAGSHIT:MONEYMONEY|RHYTHM GAMING:DEMADE|RITZ DX:REST IN PEACE LOL|nEWGROUNDS IS DOWN!:pLEASE sTAND bY ♥ |BACK THE FULL ASS GAME:NOW|NEWGROUNDS:FOREVER|RATE FIVE:PLS NO BLAM|GAME OF THE YEAR:FOREVER|STREAM CHUCKIE FINSTER:ON SPOTIFY|NEVER FORGET TO:PRAY TO GOD|LIKE PARAPPA:BUT COOLER|HATSUNE MIKU:BIGGEST INSPIRATION|WOMEN ARE REAL:THIS IS OFFICIAL|DANCIN:FOREVER|DOPE ASS GAME:PLAYSTATION MAGAZINE|GO MANGO:GO MANGO|DONT PLAY RUST:WE ONLY FUNKIN'|GOODBYE:MY PENIS|HOW I ACCIDENTALLY:MADE FNF IN pico-8|YOOOOOOOOO:yooooooooo|YOU ALREADY KNOW:WE REALLY OUT HERE| :WE HAVE FUN HERE|CLOUD BASHERS:BEST RHYTHM GAME|SUPER PICKLE MILK:ITS THE SAME THING|TURNIP BOY:COMMITS FUNK EVASION|THE LAST FUNK:PIPIN' HOT|PERFECT LAWN:ONE BROWN SPOT|wEEK 7:YES ITS HERE|YOURE SO SUSSY:I KNOW YOU TOOK MY FORTNITE CARD|$19 FORTNITE CARD:WHO WANTS IT?|DARNELL FOR PRESIDENT!:HE STILL HAS 5 YEARS TO LIVE|THAT'LL BE 15 DOLLARS:YOU ARE THE PRESIDENT| :NAME A WOMAN|FUCKIN' STEAK BABY:YEAH|NINJAMUFFIN'S BEEN REAL QUIET:SINCE WEEK 7 DROPPED|DOWNSCROLL:NEVER HEARD OF IT|WE ACTUALLY FUCKING:UPDATED IT|YES...:WE ADDED WEEK 2|CHECK OUT THE MODS:ON LEXALOFFLE|THE MODDING SCENE:IS INSANE|I ADDED MORE:SPLASH TEXT|NOW WITH:WEEK 2|HORSE:OOH AH OOH AH|WEEK 8:NEVER HAPPENING LMAO|JINGLE:BALLS| :PROBLEM NOOB?|WE UPDATED IT:TWICE|WE NEED:MORE SPLASH TEXT|WE MADE WEEK 5:IN A DAY|GO PICO GO GO:GO PICO, YEAH|YOU CAN USE dfjk NOW:CRY ABOUT IT|dfjk IS REAL:THIS IS OFFICIAL|KEYBINDS?:WHAT?|FUNKY-US MCPUNK:HE'S FUNKING OUT HIS PUNK|WE HAVE ALL THE WEEKS NOW:YES, ACTUALLY|DID YOU KNOW JOE SWANSON SAYS:FORTNITE IN FAMILY GUY LOL\""
        "\tlocal _splash = split(_splashs,\"|\")"
        "\treturn split(_splash[flr(rnd(#_splash))+1],\":\")"
        "end"))
    (def-pico-function
      (name fade0)
      (params (i))
      (line-range (255 261))
      (api-calls (flr pal))
      (called-functions ())
      (body-lines
        "function fade0(i)"
        "for c=0,15 do"
        "  if flr(i+1)>=16 then"
        "pal(c,0,1)"
        "else"
        "pal(c,fadetable0[c+1][flr(i+1)],1)"
        "end"))
    (def-pico-function
      (name fade1)
      (params (i))
      (line-range (285 291))
      (api-calls (flr pal))
      (called-functions ())
      (body-lines
        "function fade1(i)"
        " for c=0,15 do"
        "  if flr(i+1)>=16 then"
        "   pal(c,7,1)"
        "  else"
        "      pal(c,fadetable1[c+1][flr(i+1)],1)"
        "     end"))
    (def-pico-function
      (name draw_girlfriend)
      (params (_x _y))
      (line-range (296 305))
      (api-calls (flr sspr))
      (called-functions ())
      (body-lines
        "function draw_girlfriend(_x,_y)"
        "\tif flr(step/(inc*4))%2==0 then"
        "\t\tsspr(2,95,13,15,_x+30,_y+31)"
        "\t\tsspr(2,95,13,15,_x-12,_y+31,12,15,true)"
        "\t\tsspr(0,0,30,46,_x,_y)"
        "\telse"
        "\t\tsspr(15,95,12,15,_x+30,_y+31)"
        "\t\tsspr(15,95,12,15,_x-12+1,_y+31,11,15,true)"
        "\t\tsspr(0,46,30,47,_x,_y-1)"
        "\tend"))
    (def-pico-function
      (name draw_logo)
      (params (_id _x _y))
      (line-range (310 317))
      (api-calls (sspr))
      (called-functions ())
      (body-lines
        "function draw_logo(_id,_x,_y)"
        "\tif _id == 0 then"
        "\t\tsspr(58,0,70,42,_x-35,_y)"
        "\telseif _id == 1 then"
        "\t\tsspr(57,43,71,42,_x-35,_y)"
        "\telseif _id == 2 then"
        "\t\tsspr(58,86,70,43,_x-35,_y)"
        "\tend")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id 0 #:grid (0 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999992" "99999924" "9999994f" "99929944" "99929224"))
      (def-pico-sprite #:id 1 #:grid (1 0) #:nonzero-pixels 64 #:rows ("99992222" "99999242" "92222224" "44444444" "4444444f" "f44ff44f" "44f4f4f4" "44444444"))
      (def-pico-sprite #:id 2 #:grid (2 0) #:nonzero-pixels 64 #:rows ("99999999" "22299999" "44442999" "44f44299" "44f44499" "ff444429" "44444429" "44444429"))
      (def-pico-sprite #:id 3 #:grid (3 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 4 #:grid (4 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 5 #:grid (5 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 6 #:grid (6 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 7 #:grid (7 0) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999911" "99999911"))
      (def-pico-sprite #:id 8 #:grid (8 0) #:nonzero-pixels 52 #:rows ("99999999" "99999911" "99911100" "99100028" "91028888" "10288888" "10288888" "10888000"))
      (def-pico-sprite #:id 9 #:grid (9 0) #:nonzero-pixels 33 #:rows ("11111199" "00000011" "88808001" "88002000" "80808080" "88002000" "88208002" "82000008"))
      (def-pico-sprite #:id 10 #:grid (10 0) #:nonzero-pixels 45 #:rows ("99999999" "99999999" "11119991" "00011111" "00000000" "88202800" "88808882" "80808008"))
      (def-pico-sprite #:id 11 #:grid (11 0) #:nonzero-pixels 39 #:rows ("99991199" "11110019" "00010801" "08800801" "08800280" "08800080" "02808808" "80888808"))
      (def-pico-sprite #:id 12 #:grid (12 0) #:nonzero-pixels 42 #:rows ("91191911" "91191111" "99111111" "11000000" "10288200" "00888000" "00888000" "00882082"))
      (def-pico-sprite #:id 13 #:grid (13 0) #:nonzero-pixels 43 #:rows ("99999111" "19911100" "11110000" "00008880" "02208880" "28820280" "88882080" "08888080"))
      (def-pico-sprite #:id 14 #:grid (14 0) #:nonzero-pixels 47 #:rows ("11119999" "00001119" "88820001" "28888820" "00088882" "88088888" "88088888" "88088000"))
      (def-pico-sprite #:id 15 #:grid (15 0) #:nonzero-pixels 61 #:rows ("99999999" "99999999" "99999999" "11999999" "01999999" "01999999" "01999999" "11999999"))
      (def-pico-sprite #:id 16 #:grid (0 1) #:nonzero-pixels 63 #:rows ("99944244" "99924242" "99992222" "99999222" "99999224" "99999244" "99999942" "99999940"))
      (def-pico-sprite #:id 17 #:grid (1 1) #:nonzero-pixels 58 #:rows ("44444444" "224442ee" "2e24e220" "2e00ee40" "2ee0eff4" "2ef4ffff" "efff2082" "effff88f"))
      (def-pico-sprite #:id 18 #:grid (2 1) #:nonzero-pixels 64 #:rows ("44444229" "244ee429" "e22fe242" "2e2f2222" "f4222249" "f4424442" "f2244444" "f4244444"))
      (def-pico-sprite #:id 19 #:grid (3 1) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "29999999" "99999999" "99999999" "92999999" "42999999" "29999999"))
      (def-pico-sprite #:id 20 #:grid (4 1) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 21 #:grid (5 1) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 22 #:grid (6 1) #:nonzero-pixels 64 #:rows ("99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999" "99999999"))
      (def-pico-sprite #:id 23 #:grid (7 1) #:nonzero-pixels 60 #:rows ("99999991" "99999911" "99999111" "99999911" "99999111" "99999100" "99991028" "99991088"))
      (def-pico-sprite #:id 24 #:grid (8 1) #:nonzero-pixels 47 #:rows ("10888880" "10888880" "00888008" "02888028" "08888088" "28888088" "88888082" "88888000"))
      (def-pico-sprite #:id 25 #:grid (9 1) #:nonzero-pixels 36 #:rows ("00000008" "82088028" "88088088" "02088088" "00880088" "00820000" "00006777" "67777777"))
      (def-pico-sprite #:id 26 #:grid (10 1) #:nonzero-pixels 34 #:rows ("20808000" "00808208" "08808888" "88208888" "82028808" "00008000" "76000000" "77000677"))
      (def-pico-sprite #:id 27 #:grid (11 1) #:nonzero-pixels 37 #:rows ("80882028" "80880888" "80880288" "80880088" "20282088" "00022028" "00000000" "60067600"))
      (def-pico-sprite #:id 28 #:grid (12 1) #:nonzero-pixels 35 #:rows ("20880288" "80880082" "88880200" "88880808" "08880802" "00820800" "00000820" "06760000"))
      (def-pico-sprite #:id 29 #:grid (13 1) #:nonzero-pixels 31 #:rows ("08088088" "08088088" "08000088" "88088080" "88008020" "88822000" "22000000" "00077000"))
      (def-pico-sprite #:id 30 #:grid (14 1) #:nonzero-pixels 40 #:rows ("88088011" "88088201" "88088801" "88088800" "28088880" "22028820" "00002800" "67600000"))
      (def-pico-sprite #:id 31 #:grid (15 1) #:nonzero-pixels 55 #:rows ("19999999" "99999999" "19999999" "11111999" "00000199" "06760199" "77760199" "67701199")))
    (gff-flags)
    (map-rows)
    (sfx-tracks
      (def-pico-sfx #:id 0 #:editor-mode 183 #:speed 16 #:loop (0 32) #:active-notes 24)
      (def-pico-sfx #:id 1 #:editor-mode 183 #:speed 16 #:loop (0 32) #:active-notes 23)
      (def-pico-sfx #:id 2 #:editor-mode 1 #:speed 1 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 3 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 8)
      (def-pico-sfx #:id 4 #:editor-mode 183 #:speed 16 #:loop (0 32) #:active-notes 13)
      (def-pico-sfx #:id 5 #:editor-mode 1 #:speed 8 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 6 #:editor-mode 0 #:speed 16 #:loop (0 0) #:active-notes 0)
      (def-pico-sfx #:id 7 #:editor-mode 0 #:speed 16 #:loop (0 0) #:active-notes 0)
      (def-pico-sfx #:id 8 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 9 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 10 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 14)
      (def-pico-sfx #:id 11 #:editor-mode 1 #:speed 16 #:loop (0 32) #:active-notes 3)
      (def-pico-sfx #:id 12 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 10)
      (def-pico-sfx #:id 13 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 24)
      (def-pico-sfx #:id 14 #:editor-mode 209 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 15 #:editor-mode 209 #:speed 16 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 16 #:editor-mode 209 #:speed 16 #:loop (0 0) #:active-notes 26))
    (music-patterns
      (def-pico-music #:pattern 0 #:flags 0 #:channels (8 0 73 9))
      (def-pico-music #:pattern 1 #:flags 0 #:channels (12 4 77 13))
      (def-pico-music #:pattern 2 #:flags 1 #:channels (8 0 73 9))
      (def-pico-music #:pattern 3 #:flags 0 #:channels (8 0 73 9))
      (def-pico-music #:pattern 4 #:flags 0 #:channels (8 0 73 9))
      (def-pico-music #:pattern 5 #:flags 0 #:channels (12 4 77 13))
      (def-pico-music #:pattern 6 #:flags 0 #:channels (10 1 9 80))
      (def-pico-music #:pattern 7 #:flags 0 #:channels (10 1 9 80))
      (def-pico-music #:pattern 8 #:flags 0 #:channels (10 1 9 80))
      (def-pico-music #:pattern 9 #:flags 2 #:channels (10 1 9 80))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      "--friday night funkin' in pico-8"
      "--made by carson k and chris w"
      ""
      "function _init()"
      "\tpoke(0x5f2d,1)"
      "\tcartdata(\"ckcw_fnfp8\")"
      "\tstep = 0"
      "\tinc = 509/64--509/32"
      "\tlogo = 1"
      "\tmenustate = -1"
      "\tfade = 0"
      "\tfading = -1"
      "\tsplash_init()"
      "\tmusic(0)"
      "\tsynctime = 509"
      "\tdset(60,0)"
      "\tif(flr(rnd(100)) == 0) logo = 2"
      "end"
      ""
      "function _update60()"
      "\t--step = stat(26) + (stat(24)*  509)"
      "\tif(menustate == 0 or menustate == 1) menu_update()"
      "\tif(menustate == -1) splash_update()"
      "\tstep+=1"
      "\tpoke(0x5f30,1)"
      "\t--if(stat(26) > synctime) synctime = stat(26)"
      "end"
      ""
      "function _draw()"
      "\tcls()"
      "\tpalt(0,false)"
      "\tpalt(9,true)"
      "\trectfill(0,0,128,128,0)"
      "\tcolor(6)"
      "\tif(menustate == -1) splash_draw()"
      "\tif(menustate == 0 or menustate == 1) menu_draw()"
      "\tif fading > -1 then"
      "\t\tif(fading == 0) fade0(ceil(fade))"
      "\t\tif(fading == 1) fade1(ceil(fade))"
      "\t\tif(fading == 2) fade0(15-ceil(fade))"
      "\t\tif(fading == 3) fade1(15-ceil(fade))"
      "\t\tif(fade > 0) fade -= 0.5"
      "\t\tif fade == 0.5 and menustate == 0 and fading == 2 then"
      "\t\t\t--fade = 15"
      "\t\t\t--fading = 0"
      "\t\t\t--menustate = 1"
      "\t\t\tdset(59,max(0,stat(24)-2))"
      "\t\t\tload(\"#fnf_select\")"
      "\t\tend"
      "\t\tif fade == 0 and menustate == 1 and fading == 2 then"
      "\t\t\t--load cart"
      "\t\t\tif not loading then"
      "\t\t\t\tmusic(-1)"
      "\t\t\t\tload(menubtns[state+1][4])"
      "\t\t\t\tloading = true"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "end"
      "-->8"
      "--main menu"
      "function menu_init()"
      "\tmenustate = 0"
      "\tstate = 0"
      "\tnextstate = -1"
      "\tstarting = -1"
      "\tloading = false"
      "end"
      ""
      "function menu_update()"
      "\tif nextstate > 0 then"
      "\t\tnextstate -= 1"
      "\t\tif nextstate == 0 then"
      "\t\t\tfading = 2"
      "\t\t\tfade = 15"
      "\t\t\tnextstate = 0"
      "\t\tend"
      "\tend"
      "\t"
      "\tif starting > 0 then"
      "\t\tstarting -= 1"
      "\t\tif starting == 0 then"
      "\t\t\tfading = 2"
      "\t\t\tfade = 15"
      "\t\tend"
      "\tend"
      "\t"
      "\tif menustate == 0 and nextstate == -1 then"
      "\t\t--press enter to start"
      "\t\tif btnp() == 64 then"
      "\t\t\tnextstate = 30"
      "\t\t\tsfx(5,2)"
      "\t\t\tpoke(0x5f30,1)"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function menu_draw()"
      "\tif menustate == 0 then"
      "\t\trectfill(0,0,128,128,0)"
      "\t\t--girlfriend outline"
      "\t\tfor i=0,15 do"
      "\t\t\tpal(i,12)"
      "\t\tend"
      "\t\tdraw_girlfriend(49-1,60)"
      "\t\tfor i=0,15 do"
      "\t\t\tpal(i,14)"
      "\t\tend"
      "\t\tdraw_girlfriend(49+1,60+1)"
      "\t\tfor i=0,15 do"
      "\t\t\tpal(i,i)"
      "\t\tend"
      "\t\t--girlfriend"
      "\t\tdraw_girlfriend(49,60)"
      "\t\t"
      "\t\t--logo"
      "\t\tdraw_logo(logo,63,6)"
      "\t\t"
      "\t\tlocal _incc = 4"
      "\t\tif(nextstate > 0) _incc = 1"
      "\t\tif flr(step/(inc*_incc))%2 == 1 then"
      "\t\t\tlocal _tx = \"pRESS eNTER TO bEGIN\""
      "\t\t\tfor i=-1,1 do"
      "\t\t\t\tfor j=-1,1 do"
      "\t\t\t\t\tprint(_tx,i+64-#_tx*2,j+114,0)"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\t\tprint(_tx,64-#_tx*2,114,7)"
      "\t\tend"
      "\tend"
      "end"
      "-->8"
      "--splash screen"
      ""
      "function splash_init()"
      "\tsplashstate = 0"
      "\tsplashtext = get_splash_text()"
      "\tispresident = flr(rnd(100)) == 0"
      "end"
      ""
      "function splash_update()"
      "\tif btnp() == 64 then"
      "\t\tsplashstate = 0"
      "\t\tmenu_init()"
      "\t\tfading = 1"
      "\t\tfade = 15"
      "\t\tpoke(0x5f30,1)"
      "\tend"
      "\tif splashstate == 0 and step >= inc*6 then"
      "\t\tsplashstate = 1"
      "\telseif splashstate == 1 and step >= inc*16 then"
      "\t\tsplashstate = 2"
      "\telseif splashstate == 2 and step >= inc*22 then"
      "\t\tsplashstate = 3"
      "\telseif splashstate == 3 and step >= inc*32 then"
      "\t\tsplashstate = 4"
      "\telseif splashstate == 4 and step >= inc*38 then"
      "\t\tsplashstate = 5"
      "\telseif splashstate == 5 and step >= inc*48 then"
      "\t\tsplashstate = 6"
      "\telseif splashstate == 6 and step >= inc*52 then"
      "\t\tsplashstate = 7"
      "\telseif splashstate == 7 and step >= inc*56 then"
      "\t\tsplashstate = 8"
      "\telseif splashstate == 8 and step >= inc*60 then"
      "\t\tsplashstate = 9"
      "\telseif splashstate == 9 and step >= inc*64 then"
      "\t\tsplashstate = 0"
      "\t\tmenu_init()"
      "\t\tfading = 1"
      "\t\tfade = 15"
      "\tend"
      "end"
      ""
      "function splash_draw()"
      "\t--print(splashtext[1],63,63)"
      "\tlocal _tx = \"\""
      "\tif splashstate == 0 or splashstate == 1 then"
      "\t\t_tx = \"cARSON kOMPON\""
      "\t\tprint(_tx,64-#_tx*2,54)"
      "\t\t_tx = \"& cHRIS wEST\""
      "\t\tprint(_tx,64-#_tx*2,60)"
      "\t\tif splashstate == 1 then"
      "\t\t\t_tx = \"present\""
      "\t\t\tif(ispresident) _tx = \"& tHE pRESIDENT\""
      "\t\t\tprint(_tx,64-#_tx*2,66)"
      "\t\tend"
      "\telseif splashstate == 2 or splashstate == 3 then"
      "\t\t_tx = \"originally created by:\""
      "\t\tprint(_tx,64-#_tx*2,48)"
      "\t\tif splashstate == 3 then"
      "\t\t\t_tx = \"nINJAmUFFIN\""
      "\t\t\tprint(_tx,64-#_tx*2,54)"
      "\t\t\t_tx = \"pHANTOMaRCADE\""
      "\t\t\tprint(_tx,64-#_tx*2,60)"
      "\t\t\t_tx = \"kAWAIsPRITE\""
      "\t\t\tprint(_tx,64-#_tx*2,66)"
      "\t\t\t_tx = \"eVILsKER\""
      "\t\t\tprint(_tx,64-#_tx*2,72)"
      "\t\tend"
      "\telseif splashstate == 4 or splashstate == 5 then"
      "\t\t_tx = splashtext[1]"
      "\t\tprint(_tx,64-#_tx*2,56)"
      "\t\tif splashstate == 5 then"
      "\t\t\t_tx = splashtext[2]"
      "\t\t\tprint(_tx,64-#_tx*2,62)"
      "\t\tend"
      "\telseif splashstate == 6 or splashstate == 7 or splashstate == 8 or splashstate == 9 then"
      "\t\t_tx = \"fRIDAY\""
      "\t\tprint(_tx,64-#_tx*2,52)"
      "\t\tif splashstate >= 7 then"
      "\t\t\t_tx = \"nIGHT\""
      "\t\t\tprint(_tx,64-#_tx*2,58)"
      "\t\t\tif splashstate >= 8 then"
      "\t\t\t\t_tx = \" fUNKIN'\""
      "\t\t\t\tprint(_tx,64-#_tx*2,64)"
      "\t\t\t\tif splashstate >= 9 then"
      "\t\t\t\t\t_tx = \"pico-8\""
      "\t\t\t\t\tprint(_tx,64-#_tx*2,70)"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "end"
      ""
      "--splash texts"
      "function get_splash_text()"
      "\tlocal _splashs = \"SHOUTOUTS TO TOM FULP:LMAO|DA BABY:BIGGEST INSPIRATION|THIS GAME IS DEDICATED TO RINGO:MY FAVORITE BEATLE|THAT'S A HEALTHY LOOKING PENIS:THAT'S AN AMERICAN PENIS|pico-8 EXCLUSIVE:SPLASH TEST|REFINED TASTE IN MUSIC:IF I SAY SO MYSELF|SWAGSHIT:MONEYMONEY|RHYTHM GAMING:DEMADE|RITZ DX:REST IN PEACE LOL|nEWGROUNDS IS DOWN!:pLEASE sTAND bY ♥ |BACK THE FULL ASS GAME:NOW|NEWGROUNDS:FOREVER|RATE FIVE:PLS NO BLAM|GAME OF THE YEAR:FOREVER|STREAM CHUCKIE FINSTER:ON SPOTIFY|NEVER FORGET TO:PRAY TO GOD|LIKE PARAPPA:BUT COOLER|HATSUNE MIKU:BIGGEST INSPIRATION|WOMEN ARE REAL:THIS IS OFFICIAL|DANCIN:FOREVER|DOPE ASS GAME:PLAYSTATION MAGAZINE|GO MANGO:GO MANGO|DONT PLAY RUST:WE ONLY FUNKIN'|GOODBYE:MY PENIS|HOW I ACCIDENTALLY:MADE FNF IN pico-8|YOOOOOOOOO:yooooooooo|YOU ALREADY KNOW:WE REALLY OUT HERE| :WE HAVE FUN HERE|CLOUD BASHERS:BEST RHYTHM GAME|SUPER PICKLE MILK:ITS THE SAME THING|TURNIP BOY:COMMITS FUNK EVASION|THE LAST FUNK:PIPIN' HOT|PERFECT LAWN:ONE BROWN SPOT|wEEK 7:YES ITS HERE|YOURE SO SUSSY:I KNOW YOU TOOK MY FORTNITE CARD|$19 FORTNITE CARD:WHO WANTS IT?|DARNELL FOR PRESIDENT!:HE STILL HAS 5 YEARS TO LIVE|THAT'LL BE 15 DOLLARS:YOU ARE THE PRESIDENT| :NAME A WOMAN|FUCKIN' STEAK BABY:YEAH|NINJAMUFFIN'S BEEN REAL QUIET:SINCE WEEK 7 DROPPED|DOWNSCROLL:NEVER HEARD OF IT|WE ACTUALLY FUCKING:UPDATED IT|YES...:WE ADDED WEEK 2|CHECK OUT THE MODS:ON LEXALOFFLE|THE MODDING SCENE:IS INSANE|I ADDED MORE:SPLASH TEXT|NOW WITH:WEEK 2|HORSE:OOH AH OOH AH|WEEK 8:NEVER HAPPENING LMAO|JINGLE:BALLS| :PROBLEM NOOB?|WE UPDATED IT:TWICE|WE NEED:MORE SPLASH TEXT|WE MADE WEEK 5:IN A DAY|GO PICO GO GO:GO PICO, YEAH|YOU CAN USE dfjk NOW:CRY ABOUT IT|dfjk IS REAL:THIS IS OFFICIAL|KEYBINDS?:WHAT?|FUNKY-US MCPUNK:HE'S FUNKING OUT HIS PUNK|WE HAVE ALL THE WEEKS NOW:YES, ACTUALLY|DID YOU KNOW JOE SWANSON SAYS:FORTNITE IN FAMILY GUY LOL\""
      "\tlocal _splash = split(_splashs,\"|\")"
      "\treturn split(_splash[flr(rnd(#_splash))+1],\":\")"
      "end"
      "-->8"
      "--fades"
      ""
      "--fade to black"
      "local fadetable0={"
      "{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},"
      "{1,1,1,1,1,1,1,0,0,0,0,0,0,0,0},"
      "{2,2,2,2,2,2,1,1,1,0,0,0,0,0,0},"
      "{3,3,3,3,3,3,1,1,1,0,0,0,0,0,0},"
      "{4,4,4,2,2,2,2,2,1,1,0,0,0,0,0},"
      "{5,5,5,5,5,1,1,1,1,1,0,0,0,0,0},"
      "{6,6,13,13,13,13,5,5,5,5,1,1,1,0,0},"
      "{7,6,6,6,6,13,13,13,5,5,5,1,1,0,0},"
      "{8,8,8,8,2,2,2,2,2,2,0,0,0,0,0},"
      "{9,9,9,4,4,4,4,4,4,5,5,0,0,0,0},"
      "{10,10,9,9,9,4,4,4,5,5,5,5,0,0,0},"
      "{11,11,11,3,3,3,3,3,3,3,0,0,0,0,0},"
      "{12,12,12,12,12,3,3,1,1,1,1,1,1,0,0},"
      "{13,13,13,5,5,5,5,1,1,1,1,1,0,0,0},"
      "{14,14,14,13,4,4,2,2,2,2,2,1,1,0,0},"
      "{15,15,6,13,13,13,5,5,5,5,5,1,1,0,0}"
      "}"
      ""
      "function fade0(i)"
      "for c=0,15 do"
      "  if flr(i+1)>=16 then"
      "pal(c,0,1)"
      "else"
      "pal(c,fadetable0[c+1][flr(i+1)],1)"
      "end"
      " end"
      "end"
      ""
      "-- fade to white"
      "local fadetable1={"
      "{0,0,1,1,5,5,5,13,13,13,6,6,6,6,7},"
      "{1,1,5,5,13,13,13,13,13,6,6,6,6,6,7},"
      "{2,2,2,13,13,13,13,13,6,6,6,6,6,7,7},"
      "{3,3,3,3,13,13,13,13,6,6,6,6,6,7,7},"
      "{4,4,4,4,4,14,14,14,15,15,15,15,15,7,7},"
      "{5,5,13,13,13,13,13,6,6,6,6,6,6,7,7},"
      "{6,6,6,6,6,6,6,6,7,7,7,7,7,7,7},"
      "{7,7,7,7,7,7,7,7,7,7,7,7,7,7,7},"
      "{8,8,8,8,14,14,14,14,14,14,15,15,15,7,7},"
      "{9,9,9,10,10,10,15,15,15,15,15,15,15,7,7},"
      "{10,10,10,10,10,15,15,15,15,15,15,15,7,7,7},"
      "{11,11,11,11,11,11,6,6,6,6,6,6,6,7,7},"
      "{12,12,12,12,12,12,6,6,6,6,6,6,7,7,7},"
      "{13,13,13,13,6,6,6,6,6,6,6,6,7,7,7},"
      "{14,14,14,14,14,15,15,15,15,15,15,7,7,7,7},"
      "{15,15,15,15,15,15,15,7,7,7,7,7,7,7,7}"
      "}"
      ""
      "function fade1(i)"
      " for c=0,15 do"
      "  if flr(i+1)>=16 then"
      "   pal(c,7,1)"
      "  else"
      "      pal(c,fadetable1[c+1][flr(i+1)],1)"
      "     end"
      " end"
      "end"
      "-->8"
      "--draw chars"
      "function draw_girlfriend(_x,_y)"
      "\tif flr(step/(inc*4))%2==0 then"
      "\t\tsspr(2,95,13,15,_x+30,_y+31)"
      "\t\tsspr(2,95,13,15,_x-12,_y+31,12,15,true)"
      "\t\tsspr(0,0,30,46,_x,_y)"
      "\telse"
      "\t\tsspr(15,95,12,15,_x+30,_y+31)"
      "\t\tsspr(15,95,12,15,_x-12+1,_y+31,11,15,true)"
      "\t\tsspr(0,46,30,47,_x,_y-1)"
      "\tend"
      "end"
      "-->8"
      "--draw logo"
      ""
      "function draw_logo(_id,_x,_y)"
      "\tif _id == 0 then"
      "\t\tsspr(58,0,70,42,_x-35,_y)"
      "\telseif _id == 1 then"
      "\t\tsspr(57,43,71,42,_x-35,_y)"
      "\telseif _id == 2 then"
      "\t\tsspr(58,86,70,43,_x-35,_y)"
      "\tend"
      "end")
    (p8-section gfx
      "99999999999922229999999999999999999999999999999999999999999999999999999911111199999999999999119991191911999991111111999999999999"
      "99999999999992422229999999999999999999999999999999999999999999999999991100000011999999991111001991191111199111000000111999999999"
      "99999999922222244444299999999999999999999999999999999999999999999991110088808001111199910001080199111111111100008882000199999999"
      "999999924444444444f4429999999999999999999999999999999999999999999910002888002000000111110880080111000000000088802888882011999999"
      "999999244444444f44f4449999999999999999999999999999999999999999999102888880808080000000000880028010288200022088800008888201999999"
      "9999994ff44ff44fff44442999999999999999999999999999999999999999991028888888002000882028000880008000888000288202808808888801999999"
      "9992994444f4f4f44444442999999999999999999999999999999999999999111028888888208002888088820280880800888000888820808808888801999999"
      "99929224444444444444442999999999999999999999999999999999999999111088800082000008808080088088880800882082088880808808800011999999"
      "99944244444444444444422999999999999999999999999999999999999999911088888000000008208080008088202820880288080880888808801119999999"
      "99924242224442ee244ee42999999999999999999999999999999999999999111088888082088028008082088088088880880082080880888808820199999999"
      "999922222e24e220e22fe24229999999999999999999999999999999999991110088800888088088088088888088028888880200080000888808880119999999"
      "999992222e00ee402e2f222299999999999999999999999999999999999999110288802802088088882088888088008888880808880880808808880011111999"
      "999992242ee0eff4f422224999999999999999999999999999999999999991110888808800880088820288082028208808880802880080202808888000000199"
      "999992442ef4fffff442444292999999999999999999999999999999999991002888808800820000000080000002202800820800888220002202882006760199"
      "99999942efff2082f224444442999999999999999999999999999999999910288888808200006777760000000000000000000820220000000000280077760199"
      "99999940effff88ff424444429999999999999999999999999999999999910888888800067777777770006776006760006760000000770006760000067701199"
      "99929444002222222ef2444429999999999999999999999999999999999910888820006777777777770677777007776000777000006776067770000006601999"
      "99922444442888884ffe444442999999999999999999999999999999999910882006777777777777770777777007777700776000670770077760067600001999"
      "999244444e02222224ff444442999999999999999999999999999999999910220067777777777777770777777007777600770006770660677700077776001999"
      "999924444e00000222ff444422999999999999999999999999999999999910006777777777777777770677777606777006760007777000777700677777701999"
      "99999444e2efff4400ef244299999999999999999999999999999999999910677777777777777777770077777700777007700067776060777700777777601999"
      "9999924ff2fffffffe0ffe2299999999999999999999999999999999999106777777777777777777760067777700777067700677760670777760777776001999"
      "999111ef42ef222eff0ef22f21199999999999999999999999999999999107777777777760006777600000077700777077706776000770777770777760001999"
      "911555552ef2fff2ee46666555511999999999999999999999999999999107777777760000000000067776067760677077777770000770677777777700011999"
      "91055622fff2fee22111110665051999999999999999999999999999999106600777700066000006777777607770077077777777600776077777777700119999"
      "150122ffff22ffe21111166606015199999999999999999999999999999100000777777777600007777777707776077077777777760777077777777701119999"
      "156288822222eff00016661110655199999999999999999999999999999100000777777777700007777777707777777077777777770677067077777701199999"
      "0560228820202ef25561111110655099999999999999999999999999999110000777777777706007777777707067777067776007776077606067777760119119"
      "05611122111022fe2201111111615099999999999999999999999999999911110777777777607007777777607007777007770007777077700007777770111119"
      "55611111111022ff8201111111615599999999999999999999999999999991110777777600067007777770067606777606770007777067760006777776011199"
      "556011111111028f8211111110615599999999999999999999999999999999110777770006777007777770777700777700060007777607770000777777601119"
      "55601111110000288200111110615599999999999999999999999999999911100777770007777777777770777700677760000007777707776000777777760111"
      "55560111000000022200001106155599999999999999999999999999991110006777777607777777777770777700077776000007777606777600677777776011"
      "55556660000000000000000661555599999999999999999999999999991106777777777707777777777760677760067777777007776000777700067777777601"
      "55555116666666666666666155555599999999999999999999999999991067777777777607777777777700006770007777776007760000677600007067776601"
      "55555566000000011000006655555599999999999999999999999999991077776000770006777777777600000060006777600006600000070000006000000001"
      "55556601111111111111166066555599999999999999999999999999991060000000670000777777770001000660000660000000000100066000000000000011"
      "55560011111111111111661100655599999999999999999999999999991000000000060000700070070001110660000000000000001110066001100000000019"
      "55560111111100000016111110655599999999999999999999999999991100000000000000660000060001110000000000000100011911100011111100000119"
      "05561111111055555501111111655099999999999999999999999999991100001111111110660000000111191111100000011111119111111119999911111999"
      "01161111111055555501111111611099999999999999999999999999999111111199999911000001111199999999110001111111199119911999999999999999"
      "01160111111055555501111110611099999999999999999999999999999111199999999999111119999999999999991119911999999999999999999999999999"
      "01160111111100000011111110611099999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"
      "01156011000000000000001106511099999999999999999999999999999999999911111111199999999999999999119991191911999991111111999999999999"
      "90115660000000000000000665110999999999999999999999999999999999991110000000111199999999991111001991191111199111000000111999999999"
      "90111556660000000000666551110999999999999999999999999999999999911002888820001111199911110001020199111111111100008882000199999999"
      "99999999999999999229999999999999999999999999999999999999999999110288888882080111111100000000280111000000000088802888882011999999"
      "99999999999999999922299999999999999999999999999999999999999991102888222880020010000002888200882010288200022088800008888201999999"
      "99999999999992222224429999999999999999999999999999999999999991028882000208080800888028888820288000888000288202808808888801999999"
      "99999999999244444222222999999999999999999999999999999999999991088880000080020008882088200882088200888000888820808808888801999999"
      "99999999299444444444444429999999999999999999999999999999999911088880000288080028820288000088088800882082088880808808800011999999"
      "999999929924f444444444f442999999999999999999999999999999999111088880028888000088800888000088088820880288080880888808801119999999"
      "99999992922fffffff4f4fff44999999999999999999999999999999999111082088888882088088800288000088088880880082080880888808820199999999"
      "99999924244444f4f4ff444444299999999999999999999999999999999111020088882220288088800088800882028888880200080000888808880119999999"
      "99999924442444444444444444499999999999999999999999999999999991000088880000888028882202888820008888880808880880808808880011111999"
      "99999992224444424444444444499999999999999999999999999999999991100088882008882002888820288200008808880802880080202808888000000199"
      "999999992422e2224e24444442499999999999999999999999999999999999100288888002820000000000000000002800820800888220002202882006760199"
      "999999992222002ee20224ee44299999999999999999999999999999999999100888882000000000000000000000000000000820220000000000280077760199"
      "999999922242e00eee02e22e22299999999999999999999999999999999999110888200000000000000006776006760006760000000770006760000067701199"
      "99999992242ff44eff4f442222299999999999999999999999999999999991110220006777777760000677777007776000777000006776067770000006601999"
      "99999992442fffffffff222242999999999999999999999999999999999911100000677777777776000777777007777700776000670770077760067600001999"
      "99999299240fff2082ff242449922999999999999999999999999999999991100067777777777777000777777007777600770006770660677700077776001999"
      "9999922244400ff88ff2242442242999999999999999999999999999999910006777777776006777600677777606777006760007777000777700677777701999"
      "99999924444e2880042e424444429999999999999999999999999999999910067777776000000777700077777700777007700067776060777700777777601999"
      "999999224444288224ef244444299999999999999999999999999999999100077777760000000777700067777700777067700677760670777760777776001999"
      "999999224440222224ff244444429999999999999999999999999999999100677777700000000777600000077700777077706776000770777770777760001999"
      "9999999244200000244f244444429999999999999999999999999999999100777777700000006777067776067760677077777770000770677777777700011999"
      "99999999422effff000fe24444299999999999999999999999999999999100677777700000067776077777607770077077777777600776077777777700119999"
      "99999992ef2fffffffe2fffe22999999999999999999999999999999999100660677700000677760677777707776077077777777760777077777777701119999"
      "9991112ff2eff22efff2f22fe1199999999999999999999999999999999100000077700677777600777777707777777077777777770677067077777701199999"
      "911555555eff2ff4ef46666655511999999999999999999999999999999110000077777777776006777777707067777067776007776077606067777760119119"
      "910555624ff2feef2411110066051999999999999999999999999999999911000077777777600007777777607007777007770007777077700007777770111119"
      "1501522eff41ffef1111166610615199999999999999999999999999999991000677777760006007777770067606777606770007777067760006777776011199"
      "155628822221eff21111661111065199999999999999999999999999999991000777776000067007777770777700777700060007777607770000777777601119"
      "0556022220210ef42016111111065099999999999999999999999999999991000777770006777777777770777700677760000007777707776000777777760111"
      "05161111111052ff2261111111065099999999999999999999999999999111000777770007777777777770777700077776000007777606777600677777776011"
      "55161111111052ff8221111111065599999999999999999999999999991100006777776007777777777760677760067777777007776000777700067777777601"
      "551611111111028f8821111111065599999999999999999999999999991000677777777707777777777700006770007777776007760000677600007067776601"
      "55516111000000288820001110615599999999999999999999999999911006777777777607777777777600000060006777600006600000070000006000000001"
      "55551600000000022200000006155599999999999999999999999999911006777777770006777777770001000660000660000000000100066000000000000011"
      "55555166000000000000006661555599999999999999999999999999991000677760770000700070070001110660000000000000001110066001100000000019"
      "55555555111111111111111555555599999999999999999999999999911100007000670000660000060001110000000000000100011911100011111100000119"
      "55555566666666666666666655555599999999999999999999999999991100007010060110660000000111191111100000011111119111111119999911111999"
      "55556600000000000000000066555599999999999999999999999999999111110011100111000001111199999999110001111111199119911999999999999999"
      "55560111111111111111666110655599999999999999999999999999999111191199911999111119999999999999991119911999999999999999999999999999"
      "55601111111111111116611111065599999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"
      "05011111111110000661111111105099999999999999999999999999999999999999999911111199999999999999119991191911999991111111999999999999"
      "01011111111105555011111111101099999999999999999999999999999999999999991100000011999999991111001991191111199111000000111999999999"
      "01011111111105555011111111101099999999999999999999999999999999999991110088808001111199910001080199111111111100008882000199999999"
      "01601111110000000000111111061099999999999999999999999999999999999910002888002000000111110880080111000000000088802888882011999999"
      "01560110000000000000000110651099999999999999999999999999999999999102888880808080000000000880028010288200022088800008888201999999"
      "90155660000000000000000066510999999999999999999999999999999999991028888888002000882028000880008000888000288202808808888801999999"
      "90111556666000000006666655110999999999999999999999999999999999111028888888208002888088820280880800888000888820808808888801999999"
      "99999999999999999999999999999999999999999999999999999999999999111088800082000008808080088088880800882082088880808808800011999999"
      "99999999999999999999999999999999999999999999999999999999999999911088888000000008208080008088202820880288080880888808801119999999"
      "99000111199999900011199999999999999999999999999999999999999999111088888082088028008082088088088880880082080880888808820199999999"
      "99006555511119900655511199999999999999999999999999999999999991110088800888088088088088888088028888880200080000888808880119999999"
      "99116550000551911655000511999999999999999999999999999999999999110288802802088088882088888088008888880808880880808808880011999999"
      "99116505111065111650511065199999999999999999999999999999999991110888808800880088820288082028208808880802880080202808888011999999"
      "99116505511105111650551105199999999999999999999999999999999991002888808800200000000080000002202800820800888220002202882011999999"
      "99116501661105111650161105199999999999999999999999999999999910288888808200067600000000000000000000000820000000000000280001119999"
      "99116550011165111550001165199999999999999999999999999999999910888888800067777700000000066000677600000000676067600066000000011199"
      "99116555000655111555500655199999999999999999999999999999999910888820067777777700000067606760600060000000777077777600677600001199"
      "99116500005555111550005555199999999999999999999999999999999910882006777777777700006777760760006700000006777077777776067776000119"
      "99115011110655111501110655199999999999999999999999999999999910220677777777777700067777770700067760000007777077777777607777600111"
      "99115051111055111505111055199999999999999999999999999999999910006777777777777700677777770700077770066007777077006777707777760019"
      "99005056611051911505611051999999999999999999999999999999999910677777777777777706777777760600677760076007776067000077706777770011"
      "99005000111051911500011051999999999999999999999999999999999106777777777777777607777777606006777600077067600007000077600677776011"
      "99001101111651900100110651999999999999999999999999999999999107777777776006776000077760067067760066077066067606000077060067777019"
      "99000110000119900010001119999999999999999999999999999999999107777776000000000676077700677777700677077060677760000077000007777019"
      "99999999999999999999999999999999999999999999999999999999999106600770007600000777607600777777760677077606777770000776000007777011"
      "99999999999999999999999999999999999999999999999999999999999100000777777760000777707006777777776077077067700076007760600007777011"
      "99999999999999999999999999999999999999999999999999999999999100000777777770000777707007777777777067777077000007077606700007777011"
      "99999999999999999999999999999999999999999999999999999999999110000777777770600777707067777760777607777077000007077067000007777011"
      "99999999999999999999999999999999999999999999999999999999999911110777777760700777607606700600777707777077000007077606000067777019"
      "99999999999999999999999999999999999999999999999999999999999991110777760006700777007760066000777706777067000067077760000077776019"
      "99999999999999999999999999999999999999999999999999999999999999110777000677700777007777777600777760777007600676077776000677770119"
      "99999999999999999999999999999999999999999999999999999999999911100777000777777777067777777760777770777606777760077777606777760199"
      "99999999999999999999999999999999999999999999999999999999991110067777760777777777077777777770777760777700677600677777706777601199"
      "99999999999999999999999999999999999999999999999999999999991106777777770777777777077777777770777606777760000006707777760776001199"
      "99999999999999999999999999999999999999999999999999999999991067777777760777777777077777777760776067776066666067707776000660011119"
      "99999999999999999999999999999999999999999999999999999999991077760077000677777776077777777700660077770066600077706000066600019119"
      "99999999999999999999999999999999999999999999999999999999991060000067000077777700070677777600000067760000000067600666660000119999"
      "99999999999999999999999999999999999999999999999999999999991000000006000070070700060007006000000007000000000000600006000001199999"
      "99999999999999999999999999999999999999999999999999999999991100000000000066000600000006600000000066000100011000600000000011119999"
      "99999999999999999999999999999999999999999999999999999999991100001111111066000000000106600000100066011111111100001111111119199999"
      "99999999999999999999999999999999999999999999999999999999999111111199999100000001111110011001110001111111199110011119911199999999"
      "99999999999999999999999999999999999999999999999999999999999111199999999911111111999911119119991119911999999911119999999999999999")
    (p8-section label
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000001111111110000000000000000011000110101100000111111100000000000000000000000000000000000000000"
      "00000000000000000000000000000000000111000000011110000000000111100100110111110011100000011100000000000000000000000000000000000000"
      "00000000000000000000000000000000001100288882000111110001111000102010011111111110000888200010000000000000000000000000000000000000"
      "00000000000000000000000000000000011028888888208011111110000000028011100000000008880288888201100000000000000000000000000000000000"
      "00000000000000000000000000000000110288822288002001000000288820088201028820002208880000888820100000000000000000000000000000000000"
      "00000000000000000000000000000000102888200020808080088802888882028800088800028820280880888880100000000000000000000000000000000000"
      "00000000000000000000000000000000108888000008002000888208820088208820088800088882080880888880100000000000000000000000000000000000"
      "00000000000000000000000000000001108888000028808002882028800008808880088208208888080880880001100000000000000000000000000000000000"
      "00000000000000000000000000000011108888002888800008880088800008808882088028808088088880880111000000000000000000000000000000000000"
      "00000000000000000000000000000011108208888888208808880028800008808888088008208088088880882010000000000000000000000000000000000000"
      "00000000000000000000000000000011102008888222028808880008880088202888888020008000088880888011000000000000000000000000000000000000"
      "00000000000000000000000000000000100008888000088802888220288882000888888080888088080880888001111100000000000000000000000000000000"
      "00000000000000000000000000000000110008888200888200288882028820000880888080288008020280888800000010000000000000000000000000000000"
      "00000000000000000000000000000000010028888800282000000000000000000280082080088822000220288200676010000000000000000000000000000000"
      "00000000000000000000000000000000010088888200000000000000000000000000000082022000000000028007776010000000000000000000000000000000"
      "00000000000000000000000000000000011088820000000000000000677600676000676000000077000676000006770110000000000000000000000000000000"
      "00000000000000000000000000000000111022000677777776000067777700777600077700000677606777000000660100000000000000000000000000000000"
      "00000000000000000000000000000001110000067777777777600077777700777770077600067077007776006760000100000000000000000000000000000000"
      "00000000000000000000000000000000110006777777777777700077777700777760077000677066067770007777600100000000000000000000000000000000"
      "00000000000000000000000000000001000677777777600677760067777760677700676000777700077770067777770100000000000000000000000000000000"
      "00000000000000000000000000000001006777777600000077770007777770077700770006777606077770077777760100000000000000000000000000000000"
      "00000000000000000000000000000010007777776000000077770006777770077706770067776067077776077777600100000000000000000000000000000000"
      "00000000000000000000000000000010067777770000000077760000007770077707770677600077077777077776000100000000000000000000000000000000"
      "00000000000000000000000000000010077777770000000677706777606776067707777777000077067777777770001100000000000000000000000000000000"
      "00000000000000000000000000000010067777770000006777607777760777007707777777760077607777777770011000000000000000000000000000000000"
      "00000000000000000000000000000010066067770000067776067777770777607707777777776077707777777770111000000000000000000000000000000000"
      "00000000000000000000000000000010000007770067777760077777770777777707777777777067706707777770110000000000000000000000000000000000"
      "00000000000000000000000000000011000007777777777600677777770706777706777600777607760606777776011011000000000000000000000000000000"
      "00000000000000000000000000000001100007777777760000777777760700777700777000777707770000777777011111000000000000000000000000000000"
      "00000000000000000000000000000000100067777776000600777777006760677760677000777706776000677777601110000000000000000000000000000000"
      "00000000000000000000000000000000100077777600006700777777077770077770006000777760777000077777760111000000000000000000000000000000"
      "00000000000000000000000000000000100077777000677777777777077770067776000000777770777600077777776011100000000000000000000000000000"
      "00000000000000000000000000000011100077777000777777777777077770007777600000777760677760067777777601100000000000000000000000000000"
      "00000000000000000000000000000110000677777600777777777776067776006777777700777600077770006777777760100000000000000000000000000000"
      "00000000000000000000000000000100067777777770777777777770000677000777777600776000067760000706777660100000000000000000000000000000"
      "00000000000000000000000000001100677777777760777777777760000006000677760000660000007000000600000000100000000000000000000000000000"
      "00000000000000000000000000001100677777777000677777777000100066000066000000000010006600000000000001100000000000000000000000000000"
      "00000000000000000000000000000100067776077000070007007000111066000000000000000111006600110000000001000000000000000000000000000000"
      "00000000000000000000000000001110000700067000066000006000111000000000000010001101110001111110000011000000000000000000000000000000"
      "00000000000000000000000000000110000701006011066000000011110111110000001111111011111111000001111100000000000000000000000000000000"
      "00000000000000000000000000000011111001110011100000111110000000011000111111110011001100000000000000000000000000000000000000000000"
      "00000000000000000000000000000011110110001100011111000000000000000111001100000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000c22000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000c2220000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000000000c222222442000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000c24444422222200000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000c20c44444444444442000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c20e24f444444444f44200000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c2e22fffffff4f4fff44e0000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000c24244444f4f4ff44444420000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000c244424444444444444444e000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c22244444244444444444e000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000c2422e2224e244444424e000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000c2222002ee20224ee442e000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c22242e00eee02e22e222e000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c2242ff44eff4f4422222e000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c2442fffffffff222992ee000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000c20c240fff2082ff24299ee2200000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000c22244400ff88ff2242442242e0000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000c24444e2670062e42444442ee0000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000c224444286764ef2444442ee00000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000c224440222224ff24444442000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c244200000244676444442e00000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000c4626777700066764442ee00000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000c2662777787fe28882427ee00000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000c33328826772287ff2822821e7300000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000c1333555567727726f46b73331333e0000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000cc73556277726667241b7b037c351e0000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000cc7c35226776166671111166cc731510000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000c1cc628822221666211116611133651e000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000c053302222021066620161111333150e000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000c051333111110526622611179331330e000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000c551633311110526682211997310333e000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000c551619331111028688211193310633e000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000cbb000555169793300002888200033306155000bb10000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000cee11b7b0055551970333330022200003306155500b7b511ee000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000c1eee3333333975516603833333000003338755553333333eee100000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c15e73333333379555551187833b333313387855b5333333337e510000000000000000000000000000000000000"
      "0000000000000000000000000000000000000cc5333995611339555666678666b7b313331385b7511659793335ce000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c733336956113355660000000007b00333133337b5116599633337e000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c33381005511533608111111111111337e6c733335115500018333e000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c3786005551153338711111111113333e717c10333115555006873e000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c388550055110533378111e7103333611e1c111973115500055883e000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c15560199533010333811e7e333379111111119793335991106551e000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c15501197933010133311e33333597111111111013339791110551e000000000000000000000000000000000000"
      "00000000000000000000000000000000000000c18811933313167c331333330009000111111061013339611881ee000000000000000000000000000000000000"
      "0000000000000000000000000000000000000c31878133311333c713333300b70000000011065331133331878130000000000000000000000000000000000000"
      "0000000000000000000000000000000000000cc733337e100e33c33333313b7b3337e0000633333001e7e33337ce000000000000000000000000000000000000"
      "0000000000000000000000000000000000000ccc3333e1000e01333336633333333e7333333333e0001ee3333cce000000000000000000000000000000000000"
      "000000000000000000000000000000000000000eeeeeeeeeee0eeeeeeeeeeeeeeeeeeeeeeeeeeee0eeeeeeeeeeee000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000033000000000000000000000000000000000000033302220333022000000202000000000000000000000020000000000000000000000"
      "00000000000000000000300020203300222003302220333002200330000000302020003002000000202003302200033022203330020000000000000000000000"
      "00000000000000000000300020203030020030000200333020203000000033302020333002000000202030302020303002003300020000000000000000000000"
      "00000000000000000000300022203300020000300200303022200030000030002020300002000000202033302020333002003000000000000000000000000000"
      "00000000000000000000033020203030222033000200303020203300000033302220333022200000022030002200303002000330020000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "")
    (p8-section sfx
      "b7100020002750020500275002050a27500275002050027500205002750a275002750c275002750a27500275002750020500275002050a27500275002050027500205002750a275002750c275002750a27500275"
      "b710002018a7518a0018a7518a0018a7518a000ca7021a7522a0021a7518a0015a7021a5021a4515a7020a7518a0020a7518a0015a7020a5020a4515a7020a7518a0020a7518a0015a701ba601ba751ba601ba75"
      "010100000027000270002700027000270002700027000270002700027000270002700027000270002700027000270002700027000270002700027000270002700027000270002700027000270002700027000270"
      "000100002d0503205028050230501e050190501805017050170000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "b7100020002750020500275002050a27500275002050027500205002750a275002750c275002750a27500275002750020000200002000a20000200002000020000200002000a200002000c200002000a20000200"
      "01080000290502d05030050290402d04030040290302d03030030290202d02030020290102d010300102901000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "011000000c073000030c600000000c673000030c073000030c600000000c073000030c6730000311673000030c073000030c600000000c673000030c073000030c600000000c073000030c673000031167300003"
      "0110000000623000000c623000001862300000006230000300623000000c623000001862300000006230000000623000000c623000001862300000006230000300623000000c6230000018623000000062300000"
      "011000000c073000030c600000000c673000030c073000030c600000000c073000030c673000000c073116730c073000030c600000000c673000030c073000030c600000000c073000030c673000030c07311673"
      "011000202463024620246202460020600206002060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "011000000c073000030c600000000c673000030c073000030c600000000c073000030c6730000311673000030c073000030c000000000c673000030c000000030c073000000c000000030c673000030c00000003"
      "0110000000623006000c623006001862300600006230060000623006000c623006001862300600006230060000623006230c623006231862300623006230062300623006230c6230062318623006230062300623"
      "d11000001674016740167401674016740167401674016740167301673016730167301673016730167301673016720167201672016720167201672016720167201671016710167101671016710167101671016710"
      "d11000001674016740167401674016740167401674016740167301673016730167301672016720167201671022700227002270022700227002270022700227002270022700227002270022700227002270022700"
      "d11000001f7401f7401f7301f7301f7001f7001c7401c7401c7301c7301c7201c7201c7001c7001b7401b7401b7401b7401b7301b7301b7301b7301b7201b7201b7201b7201b7101b7101b7101b7101b7001b700")
    (p8-section music
      "00 08004909"
      "00 0c044d0d"
      "01 08004909"
      "00 08004909"
      "00 08004909"
      "00 0c044d0d"
      "00 0a010950"
      "00 0a010950"
      "00 0a010950"
      "02 0a010950"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a2d2d667269646179206e696768742066756e6b696e2720696e207069636f2d380a2d2d6d61646520627920636172736f6e206b20616e6420636872697320770a0a66756e6374696f6e205f696e697428290a09706f6b65283078356632642c31290a0963617274646174612822636b63775f666e66703822290a0973746570203d20300a09696e63203d203530392f36342d2d3530392f33320a096c6f676f203d20310a096d656e757374617465203d202d310a0966616465203d20300a0966616469")
    (hex 256 "6e67203d202d310a0973706c6173685f696e697428290a096d757369632830290a0973796e6374696d65203d203530390a09647365742836302c30290a09696628666c7228726e64283130302929203d3d203029206c6f676f203d20320a656e640a0a66756e6374696f6e205f757064617465363028290a092d2d73746570203d207374617428323629202b202873746174283234292a2020353039290a096966286d656e757374617465203d3d2030206f72206d656e757374617465203d3d203129206d656e755f75706461746528290a096966286d656e757374617465203d3d202d31292073706c6173685f75706461746528290a09737465702b3d310a")
    (hex 512 "09706f6b65283078356633302c31290a092d2d6966287374617428323629203e2073796e6374696d65292073796e6374696d65203d2073746174283236290a656e640a0a66756e6374696f6e205f6472617728290a09636c7328290a0970616c7428302c66616c7365290a0970616c7428392c74727565290a097265637466696c6c28302c302c3132382c3132382c30290a09636f6c6f722836290a096966286d656e757374617465203d3d202d31292073706c6173685f6472617728290a096966286d656e757374617465203d3d2030206f72206d656e757374617465203d3d203129206d656e755f6472617728290a09696620666164696e67203e202d31")
    (hex 768 "207468656e0a0909696628666164696e67203d3d203029206661646530286365696c286661646529290a0909696628666164696e67203d3d203129206661646531286365696c286661646529290a0909696628666164696e67203d3d2032292066616465302831352d6365696c286661646529290a0909696628666164696e67203d3d2033292066616465312831352d6365696c286661646529290a090969662866616465203e2030292066616465202d3d20302e350a090969662066616465203d3d20302e3520616e64206d656e757374617465203d3d203020616e6420666164696e67203d3d2032207468656e0a0909092d2d66616465203d2031350a09")
    (hex 1024 "09092d2d666164696e67203d20300a0909092d2d6d656e757374617465203d20310a090909647365742835392c6d617828302c73746174283234292d3229290a0909096c6f6164282223666e665f73656c65637422290a0909656e640a090969662066616465203d3d203020616e64206d656e757374617465203d3d203120616e6420666164696e67203d3d2032207468656e0a0909092d2d6c6f616420636172740a0909096966206e6f74206c6f6164696e67207468656e0a090909096d75736963282d31290a090909096c6f6164286d656e7562746e735b73746174652b315d5b345d290a090909096c6f6164696e67203d20747275650a090909656e64")
    (hex 1280 "0a0909656e640a09656e640a656e640a2d2d3e380a2d2d6d61696e206d656e750a66756e6374696f6e206d656e755f696e697428290a096d656e757374617465203d20300a097374617465203d20300a096e6578747374617465203d202d310a097374617274696e67203d202d310a096c6f6164696e67203d2066616c73650a656e640a0a66756e6374696f6e206d656e755f75706461746528290a096966206e6578747374617465203e2030207468656e0a09096e6578747374617465202d3d20310a09096966206e6578747374617465203d3d2030207468656e0a090909666164696e67203d20320a09090966616465203d2031350a0909096e65787473")
    (hex 1536 "74617465203d20300a0909656e640a09656e640a090a096966207374617274696e67203e2030207468656e0a09097374617274696e67202d3d20310a09096966207374617274696e67203d3d2030207468656e0a090909666164696e67203d20320a09090966616465203d2031350a0909656e640a09656e640a090a096966206d656e757374617465203d3d203020616e64206e6578747374617465203d3d202d31207468656e0a09092d2d707265737320656e74657220746f2073746172740a090969662062746e702829203d3d203634207468656e0a0909096e6578747374617465203d2033300a09090973667828352c32290a090909706f6b65283078")
    (hex 1792 "356633302c31290a0909656e640a09656e640a656e640a0a66756e6374696f6e206d656e755f6472617728290a096966206d656e757374617465203d3d2030207468656e0a09097265637466696c6c28302c302c3132382c3132382c30290a09092d2d6769726c667269656e64206f75746c696e650a0909666f7220693d302c313520646f0a09090970616c28692c3132290a0909656e640a0909647261775f6769726c667269656e642834392d312c3630290a0909666f7220693d302c313520646f0a09090970616c28692c3134290a0909656e640a0909647261775f6769726c667269656e642834392b312c36302b31290a0909666f7220693d302c3135")
    (hex 2048 "20646f0a09090970616c28692c69290a0909656e640a09092d2d6769726c667269656e640a0909647261775f6769726c667269656e642834392c3630290a09090a09092d2d6c6f676f0a0909647261775f6c6f676f286c6f676f2c36332c36290a09090a09096c6f63616c205f696e6363203d20340a09096966286e6578747374617465203e203029205f696e6363203d20310a0909696620666c7228737465702f28696e632a5f696e636329292532203d3d2031207468656e0a0909096c6f63616c205f7478203d2022705245535320654e54455220544f20624547494e220a090909666f7220693d2d312c3120646f0a09090909666f72206a3d2d312c31")
    (hex 2304 "20646f0a09090909097072696e74285f74782c692b36342d235f74782a322c6a2b3131342c30290a09090909656e640a090909656e640a0909097072696e74285f74782c36342d235f74782a322c3131342c37290a0909656e640a09656e640a656e640a2d2d3e380a2d2d73706c6173682073637265656e0a0a66756e6374696f6e2073706c6173685f696e697428290a0973706c6173687374617465203d20300a0973706c61736874657874203d206765745f73706c6173685f7465787428290a096973707265736964656e74203d20666c7228726e64283130302929203d3d20300a656e640a0a66756e6374696f6e2073706c6173685f75706461746528")
    (hex 2560 "290a0969662062746e702829203d3d203634207468656e0a090973706c6173687374617465203d20300a09096d656e755f696e697428290a0909666164696e67203d20310a090966616465203d2031350a0909706f6b65283078356633302c31290a09656e640a0969662073706c6173687374617465203d3d203020616e642073746570203e3d20696e632a36207468656e0a090973706c6173687374617465203d20310a09656c736569662073706c6173687374617465203d3d203120616e642073746570203e3d20696e632a3136207468656e0a090973706c6173687374617465203d20320a09656c736569662073706c6173687374617465203d3d2032")
    (hex 2816 "20616e642073746570203e3d20696e632a3232207468656e0a090973706c6173687374617465203d20330a09656c736569662073706c6173687374617465203d3d203320616e642073746570203e3d20696e632a3332207468656e0a090973706c6173687374617465203d20340a09656c736569662073706c6173687374617465203d3d203420616e642073746570203e3d20696e632a3338207468656e0a090973706c6173687374617465203d20350a09656c736569662073706c6173687374617465203d3d203520616e642073746570203e3d20696e632a3438207468656e0a090973706c6173687374617465203d20360a09656c736569662073706c61")
    (hex 3072 "73687374617465203d3d203620616e642073746570203e3d20696e632a3532207468656e0a090973706c6173687374617465203d20370a09656c736569662073706c6173687374617465203d3d203720616e642073746570203e3d20696e632a3536207468656e0a090973706c6173687374617465203d20380a09656c736569662073706c6173687374617465203d3d203820616e642073746570203e3d20696e632a3630207468656e0a090973706c6173687374617465203d20390a09656c736569662073706c6173687374617465203d3d203920616e642073746570203e3d20696e632a3634207468656e0a090973706c6173687374617465203d20300a")
    (hex 3328 "09096d656e755f696e697428290a0909666164696e67203d20310a090966616465203d2031350a09656e640a656e640a0a66756e6374696f6e2073706c6173685f6472617728290a092d2d7072696e742873706c617368746578745b315d2c36332c3633290a096c6f63616c205f7478203d2022220a0969662073706c6173687374617465203d3d2030206f722073706c6173687374617465203d3d2031207468656e0a09095f7478203d2022634152534f4e206b4f4d504f4e220a09097072696e74285f74782c36342d235f74782a322c3534290a09095f7478203d2022262063485249532077455354220a09097072696e74285f74782c36342d235f7478")
    (hex 3584 "2a322c3630290a090969662073706c6173687374617465203d3d2031207468656e0a0909095f7478203d202270726573656e74220a0909096966286973707265736964656e7429205f7478203d2022262074484520705245534944454e54220a0909097072696e74285f74782c36342d235f74782a322c3636290a0909656e640a09656c736569662073706c6173687374617465203d3d2032206f722073706c6173687374617465203d3d2033207468656e0a09095f7478203d20226f726967696e616c6c7920637265617465642062793a220a09097072696e74285f74782c36342d235f74782a322c3438290a090969662073706c6173687374617465203d")
    (hex 3840 "3d2033207468656e0a0909095f7478203d20226e494e4a416d554646494e220a0909097072696e74285f74782c36342d235f74782a322c3534290a0909095f7478203d20227048414e544f4d615243414445220a0909097072696e74285f74782c36342d235f74782a322c3630290a0909095f7478203d20226b41574149735052495445220a0909097072696e74285f74782c36342d235f74782a322c3636290a0909095f7478203d20226556494c734b4552220a0909097072696e74285f74782c36342d235f74782a322c3732290a0909656e640a09656c736569662073706c6173687374617465203d3d2034206f722073706c6173687374617465203d3d")
    (hex 4096 "2035207468656e0a09095f7478203d2073706c617368746578745b315d0a09097072696e74285f74782c36342d235f74782a322c3536290a090969662073706c6173687374617465203d3d2035207468656e0a0909095f7478203d2073706c617368746578745b325d0a0909097072696e74285f74782c36342d235f74782a322c3632290a0909656e640a09656c736569662073706c6173687374617465203d3d2036206f722073706c6173687374617465203d3d2037206f722073706c6173687374617465203d3d2038206f722073706c6173687374617465203d3d2039207468656e0a09095f7478203d2022665249444159220a09097072696e74285f74")
    (hex 4352 "782c36342d235f74782a322c3532290a090969662073706c6173687374617465203e3d2037207468656e0a0909095f7478203d20226e49474854220a0909097072696e74285f74782c36342d235f74782a322c3538290a09090969662073706c6173687374617465203e3d2038207468656e0a090909095f7478203d20222066554e4b494e27220a090909097072696e74285f74782c36342d235f74782a322c3634290a0909090969662073706c6173687374617465203e3d2039207468656e0a09090909095f7478203d20227069636f2d38220a09090909097072696e74285f74782c36342d235f74782a322c3730290a09090909656e640a090909656e64")
    (hex 4608 "0a0909656e640a09656e640a656e640a0a2d2d73706c6173682074657874730a66756e6374696f6e206765745f73706c6173685f7465787428290a096c6f63616c205f73706c61736873203d202253484f55544f55545320544f20544f4d2046554c503a4c4d414f7c444120424142593a4249474745535420494e535049524154494f4e7c544849532047414d452049532044454449434154454420544f2052494e474f3a4d59204641564f5249544520424541544c457c5448415427532041204845414c544859204c4f4f4b494e472050454e49533a54484154275320414e20414d45524943414e2050454e49537c7069636f2d38204558434c5553495645")
    (hex 4864 "3a53504c41534820544553547c524546494e454420544153544520494e204d555349433a494620492053415920534f204d5953454c467c53574147534849543a4d4f4e45594d4f4e45597c52485954484d2047414d494e473a44454d4144457c5249545a2044583a5245535420494e205045414345204c4f4c7c6e455747524f554e445320495320444f574e213a704c45415345207354414e4420625920e299a5207c4241434b205448452046554c4c204153532047414d453a4e4f577c4e455747524f554e44533a464f52455645527c5241544520464956453a504c53204e4f20424c414d7c47414d45204f462054484520594541523a464f52455645527c")
    (hex 5120 "53545245414d20434855434b49452046494e535445523a4f4e2053504f544946597c4e4556455220464f5247455420544f3a5052415920544f20474f447c4c494b4520504152415050413a42555420434f4f4c45527c48415453554e45204d494b553a4249474745535420494e535049524154494f4e7c574f4d454e20415245205245414c3a54484953204953204f4646494349414c7c44414e43494e3a464f52455645527c444f5045204153532047414d453a504c415953544154494f4e204d4147415a494e457c474f204d414e474f3a474f204d414e474f7c444f4e5420504c415920525553543a5745204f4e4c592046554e4b494e277c474f4f444259")
    (hex 5376 "453a4d592050454e49537c484f572049204143434944454e54414c4c593a4d41444520464e4620494e207069636f2d387c594f4f4f4f4f4f4f4f4f3a796f6f6f6f6f6f6f6f6f7c594f5520414c5245414459204b4e4f573a5745205245414c4c59204f555420484552457c203a574520484156452046554e20484552457c434c4f554420424153484552533a424553542052485954484d2047414d457c5355504552205049434b4c45204d494c4b3a495453205448452053414d45205448494e477c5455524e495020424f593a434f4d4d4954532046554e4b2045564153494f4e7c544845204c4153542046554e4b3a504950494e2720484f547c5045524645")
    (hex 5632 "4354204c41574e3a4f4e452042524f574e2053504f547c7745454b20373a5945532049545320484552457c594f55524520534f2053555353593a49204b4e4f5720594f5520544f4f4b204d5920464f52544e49544520434152447c24313920464f52544e49544520434152443a57484f2057414e54532049543f7c4441524e454c4c20464f5220505245534944454e54213a4845205354494c4c20484153203520594541525320544f204c4956457c54484154274c4c20424520313520444f4c4c4152533a594f55204152452054484520505245534944454e547c203a4e414d45204120574f4d414e7c4655434b494e2720535445414b20424142593a594541")
    (hex 5888 "487c4e494e4a414d554646494e2753204245454e205245414c2051554945543a53494e4345205745454b20372044524f505045447c444f574e5343524f4c4c3a4e45564552204845415244204f462049547c57452041435455414c4c59204655434b494e473a555044415445442049547c5945532e2e2e3a5745204144444544205745454b20327c434845434b204f555420544845204d4f44533a4f4e204c4558414c4f46464c457c544845204d4f4444494e47205343454e453a495320494e53414e457c49204144444544204d4f52453a53504c41534820544558547c4e4f5720574954483a5745454b20327c484f5253453a4f4f48204148204f4f482041")
    (hex 6144 "487c5745454b20383a4e455645522048415050454e494e47204c4d414f7c4a494e474c453a42414c4c537c203a50524f424c454d204e4f4f423f7c574520555044415445442049543a54574943457c5745204e4545443a4d4f52452053504c41534820544558547c5745204d414445205745454b20353a494e2041204441597c474f205049434f20474f20474f3a474f205049434f2c20594541487c594f552043414e205553452064666a6b204e4f573a4352592041424f55542049547c64666a6b204953205245414c3a54484953204953204f4646494349414c7c4b455942494e44533f3a574841543f7c46554e4b592d5553204d4350554e4b3a48452753")
    (hex 6400 "2046554e4b494e47204f5554204849532050554e4b7c5745204841564520414c4c20544845205745454b53204e4f573a5945532c2041435455414c4c597c44494420594f55204b4e4f57204a4f45205357414e534f4e20534159533a464f52544e49544520494e2046414d494c5920475559204c4f4c220a096c6f63616c205f73706c617368203d2073706c6974285f73706c617368732c227c22290a0972657475726e2073706c6974285f73706c6173685b666c7228726e6428235f73706c61736829292b315d2c223a22290a656e640a2d2d3e380a2d2d66616465730a0a2d2d6661646520746f20626c61636b0a6c6f63616c20666164657461626c6530")
    (hex 6656 "3d7b0a7b302c302c302c302c302c302c302c302c302c302c302c302c302c302c307d2c0a7b312c312c312c312c312c312c312c302c302c302c302c302c302c302c307d2c0a7b322c322c322c322c322c322c312c312c312c302c302c302c302c302c307d2c0a7b332c332c332c332c332c332c312c312c312c302c302c302c302c302c307d2c0a7b342c342c342c322c322c322c322c322c312c312c302c302c302c302c307d2c0a7b352c352c352c352c352c312c312c312c312c312c302c302c302c302c307d2c0a7b362c362c31332c31332c31332c31332c352c352c352c352c312c312c312c302c307d2c0a7b372c362c362c362c362c31332c31332c31")
    (hex 6912 "332c352c352c352c312c312c302c307d2c0a7b382c382c382c382c322c322c322c322c322c322c302c302c302c302c307d2c0a7b392c392c392c342c342c342c342c342c342c352c352c302c302c302c307d2c0a7b31302c31302c392c392c392c342c342c342c352c352c352c352c302c302c307d2c0a7b31312c31312c31312c332c332c332c332c332c332c332c302c302c302c302c307d2c0a7b31322c31322c31322c31322c31322c332c332c312c312c312c312c312c312c302c307d2c0a7b31332c31332c31332c352c352c352c352c312c312c312c312c312c302c302c307d2c0a7b31342c31342c31342c31332c342c342c322c322c322c322c322c")
    (hex 7168 "312c312c302c307d2c0a7b31352c31352c362c31332c31332c31332c352c352c352c352c352c312c312c302c307d0a7d0a0a66756e6374696f6e2066616465302869290a666f7220633d302c313520646f0a2020696620666c7228692b31293e3d3136207468656e0a70616c28632c302c31290a656c73650a70616c28632c666164657461626c65305b632b315d5b666c7228692b31295d2c31290a656e640a20656e640a656e640a0a2d2d206661646520746f2077686974650a6c6f63616c20666164657461626c65313d7b0a7b302c302c312c312c352c352c352c31332c31332c31332c362c362c362c362c377d2c0a7b312c312c352c352c31332c3133")
    (hex 7424 "2c31332c31332c31332c362c362c362c362c362c377d2c0a7b322c322c322c31332c31332c31332c31332c31332c362c362c362c362c362c372c377d2c0a7b332c332c332c332c31332c31332c31332c31332c362c362c362c362c362c372c377d2c0a7b342c342c342c342c342c31342c31342c31342c31352c31352c31352c31352c31352c372c377d2c0a7b352c352c31332c31332c31332c31332c31332c362c362c362c362c362c362c372c377d2c0a7b362c362c362c362c362c362c362c362c372c372c372c372c372c372c377d2c0a7b372c372c372c372c372c372c372c372c372c372c372c372c372c372c377d2c0a7b382c382c382c382c31342c")
    (hex 7680 "31342c31342c31342c31342c31342c31352c31352c31352c372c377d2c0a7b392c392c392c31302c31302c31302c31352c31352c31352c31352c31352c31352c31352c372c377d2c0a7b31302c31302c31302c31302c31302c31352c31352c31352c31352c31352c31352c31352c372c372c377d2c0a7b31312c31312c31312c31312c31312c31312c362c362c362c362c362c362c362c372c377d2c0a7b31322c31322c31322c31322c31322c31322c362c362c362c362c362c362c372c372c377d2c0a7b31332c31332c31332c31332c362c362c362c362c362c362c362c362c372c372c377d2c0a7b31342c31342c31342c31342c31342c31352c31352c31")
    (hex 7936 "352c31352c31352c31352c372c372c372c377d2c0a7b31352c31352c31352c31352c31352c31352c31352c372c372c372c372c372c372c372c377d0a7d0a0a66756e6374696f6e2066616465312869290a20666f7220633d302c313520646f0a2020696620666c7228692b31293e3d3136207468656e0a20202070616c28632c372c31290a2020656c73650a20202020202070616c28632c666164657461626c65315b632b315d5b666c7228692b31295d2c31290a2020202020656e640a20656e640a656e640a2d2d3e380a2d2d647261772063686172730a66756e6374696f6e20647261775f6769726c667269656e64285f782c5f79290a09696620666c72")
    (hex 8192 "28737465702f28696e632a34292925323d3d30207468656e0a09097373707228322c39352c31332c31352c5f782b33302c5f792b3331290a09097373707228322c39352c31332c31352c5f782d31322c5f792b33312c31322c31352c74727565290a09097373707228302c302c33302c34362c5f782c5f79290a09656c73650a0909737370722831352c39352c31322c31352c5f782b33302c5f792b3331290a0909737370722831352c39352c31322c31352c5f782d31322b312c5f792b33312c31312c31352c74727565290a09097373707228302c34362c33302c34372c5f782c5f792d31290a09656e640a656e640a2d2d3e380a2d2d64726177206c6f67")
    (hex 8448 "6f0a0a66756e6374696f6e20647261775f6c6f676f285f69642c5f782c5f79290a096966205f6964203d3d2030207468656e0a0909737370722835382c302c37302c34322c5f782d33352c5f79290a09656c73656966205f6964203d3d2031207468656e0a0909737370722835372c34332c37312c34322c5f782d33352c5f79290a09656c73656966205f6964203d3d2032207468656e0a0909737370722835382c38362c37302c34332c5f782d33352c5f79290a09656e640a656e640a5f5f6766785f5f0a39393939393939393939393932323232393939393939393939393939393939393939393939393939393939393939393939393939393939393939")
    (hex 8704 "393939393939393939393939393931313131313139393939393939393939393939393131393939313139313931313939393939313131313131313939393939393939393939390a39393939393939393939393939323432323232393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313130303030303031313939393939393939313131313030313939313139313131313139393131313030303030303131313939393939393939390a3939393939393939393232323232323434343434323939393939393939393939393939393939393939393939393939393939393939393939")
    (hex 8960 "3939393939393939393939313131303038383830383030313131313139393931303030313038303139393131313131313131313130303030383838323030303139393939393939390a39393939393939323434343434343434343466343432393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931303030323838383030323030303030303131313131303838303038303131313030303030303030303038383830323838383838323031313939393939390a393939393939323434343434343434663434663434343939393939393939393939393939393939393939393939393939393939393939")
    (hex 9216 "39393939393939393939393130323838383838303830383038303030303030303030303838303032383031303238383230303032323038383830303030383838383230313939393939390a39393939393934666634346666343466666634343434323939393939393939393939393939393939393939393939393939393939393939393939393939393939313032383838383838383030323030303838323032383030303838303030383030303838383030303238383230323830383830383838383830313939393939390a39393932393934343434663466346634343434343434323939393939393939393939393939393939393939393939393939393939")
    (hex 9472 "393939393939393939393131313032383838383838383230383030323838383038383832303238303838303830303838383030303838383832303830383830383838383830313939393939390a39393932393232343434343434343434343434343434323939393939393939393939393939393939393939393939393939393939393939393939393939393131313038383830303038323030303030383830383038303038383038383838303830303838323038323038383838303830383830383830303031313939393939390a3939393434323434343434343434343434343434343232393939393939393939393939393939393939393939393939393939")
    (hex 9728 "3939393939393939393939393931313038383838383030303030303030383230383038303030383038383230323832303838303238383038303838303838383830383830313131393939393939390a39393932343234323232343434326565323434656534323939393939393939393939393939393939393939393939393939393939393939393939393939393131313038383838383038323038383032383030383038323038383038383038383838303838303038323038303838303838383830383832303139393939393939390a393939393232323232653234653232306532326665323432323939393939393939393939393939393939393939393939")
    (hex 9984 "39393939393939393939393939313131303038383830303838383038383038383038383038383838383038383032383838383838303230303038303030303838383830383838303131393939393939390a39393939393232323265303065653430326532663232323239393939393939393939393939393939393939393939393939393939393939393939393939393131303238383830323830323038383038383838323038383838383038383030383838383838303830383838303838303830383830383838303031313131313939390a39393939393232343265653065666634663432323232343939393939393939393939393939393939393939393939")
    (hex 10240 "393939393939393939393939393939313131303838383830383830303838303038383832303238383038323032383230383830383838303830323838303038303230323830383838383030303030303139390a39393939393234343265663466666666663434323434343239323939393939393939393939393939393939393939393939393939393939393939393939313030323838383830383830303832303030303030303038303030303030323230323830303832303830303838383232303030323230323838323030363736303139390a3939393939393432656666663230383266323234343434343432393939393939393939393939393939393939")
    (hex 10496 "3939393939393939393939393939393931303238383838383830383230303030363737373736303030303030303030303030303030303030303832303232303030303030303030303238303037373736303139390a39393939393934306566666666383866663432343434343432393939393939393939393939393939393939393939393939393939393939393939393931303838383838383830303036373737373737373737303030363737363030363736303030363736303030303030303737303030363736303030303036373730313139390a393939323934343430303232323232323265663234343434323939393939393939393939393939393939")
    (hex 10752 "39393939393939393939393939393939393931303838383832303030363737373737373737373737303637373737373030373737363030303737373030303030363737363036373737303030303030363630313939390a39393932323434343434323838383838346666653434343434323939393939393939393939393939393939393939393939393939393939393939393931303838323030363737373737373737373737373737303737373737373030373737373730303737363030303637303737303037373736303036373630303030313939390a39393932343434343465303232323232323466663434343434323939393939393939393939393939")
    (hex 11008 "393939393939393939393939393939393939393931303232303036373737373737373737373737373737303737373737373030373737373630303737303030363737303636303637373730303037373737363030313939390a39393939323434343465303030303032323266663434343432323939393939393939393939393939393939393939393939393939393939393939393931303030363737373737373737373737373737373737303637373737373630363737373030363736303030373737373030303737373730303637373737373730313939390a3939393939343434653265666666343430306566323434323939393939393939393939393939")
    (hex 11264 "3939393939393939393939393939393939393939393931303637373737373737373737373737373737373737303037373737373730303737373030373730303036373737363036303737373730303737373737373630313939390a39393939393234666632666666666666666530666665323239393939393939393939393939393939393939393939393939393939393939393939393130363737373737373737373737373737373737373736303036373737373730303737373036373730303637373736303637303737373736303737373737363030313939390a393939313131656634326566323232656666306566323266323131393939393939393939")
    (hex 11520 "39393939393939393939393939393939393939393939393130373737373737373737373736303030363737373630303030303037373730303737373037373730363737363030303737303737373737303737373736303030313939390a39313135353535353265663266666632656534363636363535353531313939393939393939393939393939393939393939393939393939393939393130373737373737373736303030303030303030303036373737363036373736303637373037373737373737303030303737303637373737373737373730303031313939390a39313035353632326666663266656532323131313131303636353035313939393939")
    (hex 11776 "393939393939393939393939393939393939393939393939393130363630303737373730303036363030303030363737373737373630373737303037373037373737373737373630303737363037373737373737373730303131393939390a31353031323266666666323266666532313131313136363630363031353139393939393939393939393939393939393939393939393939393939393130303030303737373737373737373630303030373737373737373730373737363037373037373737373737373736303737373037373737373737373730313131393939390a3135363238383832323232326566663030303136363631313130363535313939")
    (hex 12032 "3939393939393939393939393939393939393939393939393939393130303030303737373737373737373730303030373737373737373730373737373737373037373737373737373737303637373036373037373737373730313139393939390a30353630323238383230323032656632353536313131313131303635353039393939393939393939393939393939393939393939393939393939393131303030303737373737373737373730363030373737373737373730373036373737373036373737363030373737363037373630363036373737373736303131393131390a303536313131323231313130323266653232303131313131313136313530")
    (hex 12288 "39393939393939393939393939393939393939393939393939393939393931313131303737373737373737373630373030373737373737373630373030373737373030373737303030373737373037373730303030373737373737303131313131390a35353631313131313131313032326666383230313131313131313631353539393939393939393939393939393939393939393939393939393939393939313131303737373737373630303036373030373737373737303036373630363737373630363737303030373737373036373736303030363737373737363031313139390a35353630313131313131313130323866383231313131313131303631")
    (hex 12544 "353539393939393939393939393939393939393939393939393939393939393939393131303737373737303030363737373030373737373737303737373730303737373730303036303030373737373630373737303030303737373737373630313131390a35353630313131313131303030303238383230303131313131303631353539393939393939393939393939393939393939393939393939393939393931313130303737373737303030373737373737373737373737303737373730303637373736303030303030373737373730373737363030303737373737373736303131310a3535353630313131303030303030303232323030303031313036")
    (hex 12800 "3135353539393939393939393939393939393939393939393939393939393939313131303030363737373737373630373737373737373737373737303737373730303037373737363030303030373737373630363737373630303637373737373737363031310a35353535363636303030303030303030303030303030303636313535353539393939393939393939393939393939393939393939393939393939313130363737373737373737373730373737373737373737373736303637373736303036373737373737373030373737363030303737373730303036373737373737373630310a353535353531313636363636363636363636363636363631")
    (hex 13056 "35353535353539393939393939393939393939393939393939393939393939393939313036373737373737373737373630373737373737373737373730303030363737303030373737373737363030373736303030303637373630303030373036373737363630310a35353535353536363030303030303031313030303030363635353535353539393939393939393939393939393939393939393939393939393939313037373737363030303737303030363737373737373737373630303030303036303030363737373630303030363630303030303037303030303030363030303030303030310a35353535363630313131313131313131313131313136")
    (hex 13312 "363036363535353539393939393939393939393939393939393939393939393939393939313036303030303030303637303030303737373737373737303030313030303636303030303636303030303030303030303130303036363030303030303030303030303031310a35353536303031313131313131313131313131313636313130303635353539393939393939393939393939393939393939393939393939393939313030303030303030303036303030303730303037303037303030313131303636303030303030303030303030303030313131303036363030313130303030303030303031390a3535353630313131313131313030303030303136")
    (hex 13568 "3131313131303635353539393939393939393939393939393939393939393939393939393939313130303030303030303030303030303636303030303036303030313131303030303030303030303030303130303031313931313130303031313131313130303030303131390a30353536313131313131313035353535353530313131313131313635353039393939393939393939393939393939393939393939393939393939313130303030313131313131313131303636303030303030303131313139313131313130303030303031313131313131393131313131313131393939393931313131313939390a303131363131313131313130353535353535")
    (hex 13824 "30313131313131313631313039393939393939393939393939393939393939393939393939393939393131313131313139393939393931313030303030313131313139393939393939393131303030313131313131313139393131393931313939393939393939393939393939390a30313136303131313131313035353535353530313131313131303631313039393939393939393939393939393939393939393939393939393939393131313139393939393939393939393131313131393939393939393939393939393939313131393931313939393939393939393939393939393939393939393939393939390a30313136303131313131313130303030")
    (hex 14080 "303031313131313131303631313039393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939390a30313135363031313030303030303030303030303030313130363531313039393939393939393939393939393939393939393939393939393939393939393939393931313131313131313139393939393939393939393939393939393131393939313139313931313939393939313131313131313939393939393939393939390a3930313135363630303030303030")
    (hex 14336 "3030303030303030303636353131303939393939393939393939393939393939393939393939393939393939393939393939313131303030303030303131313139393939393939393939313131313030313939313139313131313139393131313030303030303131313939393939393939390a39303131313535363636303030303030303030303636363535313131303939393939393939393939393939393939393939393939393939393939393939393931313030323838383832303030313131313139393931313131303030313032303139393131313131313131313130303030383838323030303139393939393939390a393939393939393939393939")
    (hex 14592 "39393939393232393939393939393939393939393939393939393939393939393939393939393939393939393939393939393131303238383838383838323038303131313131313130303030303030303238303131313030303030303030303038383830323838383838323031313939393939390a39393939393939393939393939393939393932323239393939393939393939393939393939393939393939393939393939393939393939393939393939313130323838383232323838303032303031303030303030323838383230303838323031303238383230303032323038383830303030383838383230313939393939390a39393939393939393939")
    (hex 14848 "393939323232323232343432393939393939393939393939393939393939393939393939393939393939393939393939393939313032383838323030303230383038303830303838383032383838383832303238383030303838383030303238383230323830383830383838383830313939393939390a39393939393939393939393234343434343232323232323939393939393939393939393939393939393939393939393939393939393939393939393939313038383838303030303038303032303030383838323038383230303838323038383230303838383030303838383832303830383830383838383830313939393939390a3939393939393939")
    (hex 15104 "3239393434343434343434343434343432393939393939393939393939393939393939393939393939393939393939393939393931313038383838303030303238383038303032383832303238383030303038383038383830303838323038323038383838303830383830383830303031313939393939390a39393939393939323939323466343434343434343434663434323939393939393939393939393939393939393939393939393939393939393939393131313038383838303032383838383030303038383830303838383030303038383038383832303838303238383038303838303838383830383830313131393939393939390a393939393939")
    (hex 15360 "39323932326666666666666634663466666634343939393939393939393939393939393939393939393939393939393939393939393131313038323038383838383838323038383038383830303238383030303038383038383838303838303038323038303838303838383830383832303139393939393939390a39393939393932343234343434346634663466663434343434343239393939393939393939393939393939393939393939393939393939393939393131313032303038383838323232303238383038383830303038383830303838323032383838383838303230303038303030303838383830383838303131393939393939390a39393939")
    (hex 15616 "393932343434323434343434343434343434343434343439393939393939393939393939393939393939393939393939393939393939393939313030303038383838303030303838383032383838323230323838383832303030383838383838303830383838303838303830383830383838303031313131313939390a39393939393939323232343434343432343434343434343434343439393939393939393939393939393939393939393939393939393939393939393939313130303038383838323030383838323030323838383832303238383230303030383830383838303830323838303038303230323830383838383030303030303139390a3939")
    (hex 15872 "3939393939393234323265323232346532343434343434323439393939393939393939393939393939393939393939393939393939393939393939393130303238383838383030323832303030303030303030303030303030303030323830303832303830303838383232303030323230323838323030363736303139390a39393939393939393232323230303265653230323234656534343239393939393939393939393939393939393939393939393939393939393939393939393130303838383838323030303030303030303030303030303030303030303030303030303030303832303232303030303030303030303238303037373736303139390a")
    (hex 16128 "39393939393939323232343265303065656530326532326532323239393939393939393939393939393939393939393939393939393939393939393939393131303838383230303030303030303030303030303030363737363030363736303030363736303030303030303737303030363736303030303036373730313139390a39393939393939323234326666343465666634663434323232323239393939393939393939393939393939393939393939393939393939393939393939313131303232303030363737373737373736303030303637373737373030373737363030303737373030303030363737363036373737303030303030363630313939")
    (hex 16384 "390a39393939393939323434326666666666666666663232323234323939393939393939393939393939393939393939393939393939393939393939393931313130303030303637373737373737373737363030303737373737373030373737373730303737363030303637303737303037373736303036373630303030313939390a3939393939323939323430666666323038326666323432343439393232393939393939393939393939393939393939393939393939393939393939393931313030303637373737373737373737373737303030373737373737303037373737363030373730303036373730363630363737373030303737373736303031")
    (hex 16640 "3939390a39393939393232323434343030666638386666323234323434323234323939393939393939393939393939393939393939393939393939393939393931303030363737373737373737363030363737373630303637373737373630363737373030363736303030373737373030303737373730303637373737373730313939390a393939393939323434343465323838303034326534323434343434323939393939393939393939393939393939393939393939393939393939393939313030363737373737373630303030303037373737303030373737373737303037373730303737303030363737373630363037373737303037373737373736")
    (hex 16896 "30313939390a39393939393932323434343432383832323465663234343434343239393939393939393939393939393939393939393939393939393939393939393130303037373737373736303030303030303737373730303036373737373730303737373036373730303637373736303637303737373736303737373737363030313939390a39393939393932323434343032323232323466663234343434343432393939393939393939393939393939393939393939393939393939393939393130303637373737373730303030303030303737373630303030303037373730303737373037373730363737363030303737303737373737303737373736")
    (hex 17152 "303030313939390a39393939393939323434323030303030323434663234343434343432393939393939393939393939393939393939393939393939393939393939393130303737373737373730303030303030363737373036373737363036373736303637373037373737373737303030303737303637373737373737373730303031313939390a3939393939393939343232656666666630303066653234343434323939393939393939393939393939393939393939393939393939393939393939313030363737373737373030303030303637373736303737373737363037373730303737303737373737373737363030373736303737373737373737")
    (hex 17408 "3730303131393939390a39393939393939326566326666666666666665326666666532323939393939393939393939393939393939393939393939393939393939393939393130303636303637373730303030303637373736303637373737373730373737363037373037373737373737373736303737373037373737373737373730313131393939390a393939313131326666326566663232656666663266323266653131393939393939393939393939393939393939393939393939393939393939393931303030303030373737303036373737373736303037373737373737303737373737373730373737373737373737373036373730363730373737")
    (hex 17664 "37373730313139393939390a39313135353535353565666632666634656634363636363635353531313939393939393939393939393939393939393939393939393939393939393131303030303037373737373737373737363030363737373737373730373036373737373036373737363030373737363037373630363036373737373736303131393131390a39313035353536323466663266656566323431313131303036363035313939393939393939393939393939393939393939393939393939393939393931313030303037373737373737373630303030373737373737373630373030373737373030373737303030373737373037373730303030")
    (hex 17920 "373737373737303131313131390a31353031353232656666343166666566313131313136363631303631353139393939393939393939393939393939393939393939393939393939393939313030303637373737373736303030363030373737373737303036373630363737373630363737303030373737373036373736303030363737373737363031313139390a3135353632383832323232316566663231313131363631313131303635313939393939393939393939393939393939393939393939393939393939393931303030373737373736303030303637303037373737373730373737373030373737373030303630303037373737363037373730")
    (hex 18176 "3030303737373737373630313131390a30353536303232323230323130656634323031363131313131313036353039393939393939393939393939393939393939393939393939393939393939313030303737373737303030363737373737373737373737303737373730303637373736303030303030373737373730373737363030303737373737373736303131310a303531363131313131313130353266663232363131313131313130363530393939393939393939393939393939393939393939393939393939393931313130303037373737373030303737373737373737373737373037373737303030373737373630303030303737373736303637")
    (hex 18432 "37373630303637373737373737363031310a35353136313131313131313035326666383232313131313131313036353539393939393939393939393939393939393939393939393939393939313130303030363737373737363030373737373737373737373736303637373736303036373737373737373030373737363030303737373730303036373737373737373630310a35353136313131313131313130323866383832313131313131313036353539393939393939393939393939393939393939393939393939393939313030303637373737373737373730373737373737373737373730303030363737303030373737373737363030373736303030")
    (hex 18688 "303637373630303030373036373737363630310a35353531363131313030303030303238383832303030313131303631353539393939393939393939393939393939393939393939393939393931313030363737373737373737373630373737373737373737373630303030303036303030363737373630303030363630303030303037303030303030363030303030303030310a3535353531363030303030303030303232323030303030303036313535353939393939393939393939393939393939393939393939393939393131303036373737373737373730303036373737373737373730303031303030363630303030363630303030303030303030")
    (hex 18944 "3130303036363030303030303030303030303031310a35353535353136363030303030303030303030303030363636313535353539393939393939393939393939393939393939393939393939393939313030303637373736303737303030303730303037303037303030313131303636303030303030303030303030303030313131303036363030313130303030303030303031390a353535353535353531313131313131313131313131313135353535353535393939393939393939393939393939393939393939393939393939313131303030303730303036373030303036363030303030363030303131313030303030303030303030303031303030")
    (hex 19200 "31313931313130303031313131313130303030303131390a35353535353536363636363636363636363636363636363635353535353539393939393939393939393939393939393939393939393939393939313130303030373031303036303131303636303030303030303131313139313131313130303030303031313131313131393131313131313131393939393931313131313939390a35353535363630303030303030303030303030303030303036363535353539393939393939393939393939393939393939393939393939393939393131313131303031313130303131313030303030313131313139393939393939393131303030313131313131")
    (hex 19456 "313139393131393931313939393939393939393939393939390a35353536303131313131313131313131313131313636363131303635353539393939393939393939393939393939393939393939393939393939393131313139313139393931313939393131313131393939393939393939393939393939313131393931313939393939393939393939393939393939393939393939393939390a3535363031313131313131313131313131313136363131313131303635353939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939")
    (hex 19712 "3939393939393939393939393939393939393939393939393939390a30353031313131313131313131303030303636313131313131313130353039393939393939393939393939393939393939393939393939393939393939393939393939393939393931313131313139393939393939393939393939393131393939313139313931313939393939313131313131313939393939393939393939390a303130313131313131313131303535353530313131313131313131303130393939393939393939393939393939393939393939393939393939393939393939393939393939393131303030303030313139393939393939393131313130303139393131")
    (hex 19968 "39313131313139393131313030303030303131313939393939393939390a30313031313131313131313130353535353031313131313131313130313039393939393939393939393939393939393939393939393939393939393939393939393939313131303038383830383030313131313139393931303030313038303139393131313131313131313130303030383838323030303139393939393939390a30313630313131313131303030303030303030303131313131313036313039393939393939393939393939393939393939393939393939393939393939393939393931303030323838383030323030303030303131313131303838303038303131")
    (hex 20224 "313030303030303030303038383830323838383838323031313939393939390a30313536303131303030303030303030303030303030303131303635313039393939393939393939393939393939393939393939393939393939393939393939393130323838383838303830383038303030303030303030303838303032383031303238383230303032323038383830303030383838383230313939393939390a3930313535363630303030303030303030303030303030303636353130393939393939393939393939393939393939393939393939393939393939393939393931303238383838383838303032303030383832303238303030383830303038")
    (hex 20480 "3030303838383030303238383230323830383830383838383830313939393939390a39303131313535363636363030303030303030363636363635353131303939393939393939393939393939393939393939393939393939393939393939393131313032383838383838383230383030323838383038383832303238303838303830303838383030303838383832303830383830383838383830313939393939390a393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931313130383838303030383230303030303838303830383030383830383838")
    (hex 20736 "38303830303838323038323038383838303830383830383830303031313939393939390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931313038383838383030303030303030383230383038303030383038383230323832303838303238383038303838303838383830383830313131393939393939390a39393030303131313139393939393930303031313139393939393939393939393939393939393939393939393939393939393939393939393939393939393131313038383838383038323038383032383030383038323038383038")
    (hex 20992 "383038383838303838303038323038303838303838383830383832303139393939393939390a39393030363535353531313131393930303635353531313139393939393939393939393939393939393939393939393939393939393939393939393939313131303038383830303838383038383038383038383038383838383038383032383838383838303230303038303030303838383830383838303131393939393939390a3939313136353530303030353531393131363535303030353131393939393939393939393939393939393939393939393939393939393939393939393939313130323838383032383032303838303838383832303838383838")
    (hex 21248 "3038383030383838383838303830383838303838303830383830383838303031313939393939390a39393131363530353131313036353131313635303531313036353139393939393939393939393939393939393939393939393939393939393939393939313131303838383830383830303838303038383832303238383038323032383230383830383838303830323838303038303230323830383838383031313939393939390a393931313635303535313131303531313136353035353131303531393939393939393939393939393939393939393939393939393939393939393939393130303238383838303838303032303030303030303030383030")
    (hex 21504 "30303030323230323830303832303830303838383232303030323230323838323031313939393939390a39393131363530313636313130353131313635303136313130353139393939393939393939393939393939393939393939393939393939393939393931303238383838383830383230303036373630303030303030303030303030303030303030303030303832303030303030303030303030303238303030313131393939390a39393131363535303031313136353131313535303030313136353139393939393939393939393939393939393939393939393939393939393939393931303838383838383830303036373737373730303030303030")
    (hex 21760 "303036363030303637373630303030303030303637363036373630303036363030303030303031313139390a39393131363535353030303635353131313535353530303635353139393939393939393939393939393939393939393939393939393939393939393931303838383832303036373737373737373730303030303036373630363736303630303036303030303030303737373037373737373630303637373630303030313139390a3939313136353030303035353535313131353530303035353535313939393939393939393939393939393939393939393939393939393939393939393130383832303036373737373737373737373030303036")
    (hex 22016 "3737373736303736303030363730303030303030363737373037373737373737363036373737363030303131390a39393131353031313131303635353131313530313131303635353139393939393939393939393939393939393939393939393939393939393939393931303232303637373737373737373737373730303036373737373737303730303036373736303030303030373737373037373737373737373630373737373630303131310a393931313530353131313130353531313135303531313130353531393939393939393939393939393939393939393939393939393939393939393939313030303637373737373737373737373737303036")
    (hex 22272 "37373737373737303730303037373737303036363030373737373037373030363737373730373737373736303031390a39393030353035363631313035313931313530353631313035313939393939393939393939393939393939393939393939393939393939393939393931303637373737373737373737373737373730363737373737373736303630303637373736303037363030373737363036373030303037373730363737373737303031310a39393030353030303131313035313931313530303031313035313939393939393939393939393939393939393939393939393939393939393939393130363737373737373737373737373737373630")
    (hex 22528 "373737373737373630363030363737373630303037373036373630303030373030303037373630303637373737363031310a39393030313130313131313635313930303130303131303635313939393939393939393939393939393939393939393939393939393939393939393130373737373737373737363030363737363030303037373736303036373036373736303036363037373036363036373630363030303037373036303036373737373031390a3939303030313130303030313139393030303130303031313139393939393939393939393939393939393939393939393939393939393939393939313037373737373736303030303030303030")
    (hex 22784 "3637363037373730303637373737373730303637373037373036303637373736303030303037373030303030373737373031390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393130363630303737303030373630303030303737373630373630303737373737373736303637373037373630363737373737303030303737363030303030373737373031310a393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931303030303037373737373737363030")
    (hex 23040 "30303737373730373030363737373737373737363037373037373036373730303037363030373736303630303030373737373031310a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393130303030303737373737373737303030303737373730373030373737373737373737373036373737373037373030303030373037373630363730303030373737373031310a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393131303030303737373737373737")
    (hex 23296 "303630303737373730373036373737373736303737373630373737373037373030303030373037373036373030303030373737373031310a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931313131303737373737373736303730303737373630373630363730303630303737373730373737373037373030303030373037373630363030303036373737373031390a3939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931313130373737373630")
    (hex 23552 "3030363730303737373030373736303036363030303737373730363737373036373030303036373037373736303030303037373737363031390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393131303737373030303637373730303737373030373737373737373630303737373736303737373030373630303637363037373737363030303637373737303131390a393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313131303037373730")
    (hex 23808 "30303737373737373737373036373737373737373736303737373737303737373630363737373736303037373737373630363737373736303139390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313131303036373737373736303737373737373737373037373737373737373737303737373736303737373730303637373630303637373737373730363737373630313139390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313130363737373737")
    (hex 24064 "373737303737373737373737373037373737373737373737303737373630363737373736303030303030363730373737373736303737363030313139390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313036373737373737373736303737373737373737373037373737373737373736303737363036373737363036363636363036373730373737363030303636303031313131390a3939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393931303737373630")
    (hex 24320 "3037373030303637373737373737363037373737373737373730303636303037373737303036363630303037373730363030303036363630303031393131390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313036303030303036373030303037373737373730303037303637373737373630303030303036373736303030303030303036373630303636363636303030303131393939390a393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393130303030")
    (hex 24576 "30303030363030303037303037303730303036303030373030363030303030303030373030303030303030303030303630303030363030303030313139393939390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313130303030303030303030303036363030303630303030303030363630303030303030303036363030303130303031313030303630303030303030303031313131393939390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939313130")
    (hex 24832 "303030313131313131313036363030303030303030303130363630303030303130303036363031313131313131313130303030313131313131313131393139393939390a39393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393131313131313139393939393130303030303030313131313131303031313030313131303030313131313131313139393131303031313131393931313139393939393939390a3939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939")
    (hex 25088 "3131313139393939393939393931313131313131313939393931313131393131393939313131393931313939393939393931313131393939393939393939393939393939390a5f5f6c6162656c5f5f0a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 25344 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 25600 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 25856 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030313131313131313131303030303030303030303030303030303031313030303131303130313130303030303131313131313130303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030313131303030")
    (hex 26112 "3030303031313131303030303030303030303131313130303130303131303131313131303031313130303030303031313130303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030313130303238383838323030303131313131303030313131313030303130323031303031313131313131313131303030303838383230303031303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030313130323838")
    (hex 26368 "38383838383230383031313131313131303030303030303032383031313130303030303030303030383838303238383838383230313130303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303131303238383832323238383030323030313030303030303238383832303038383230313032383832303030323230383838303030303838383832303130303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303130323838")
    (hex 26624 "383230303032303830383038303038383830323838383838323032383830303038383830303032383832303238303838303838383838303130303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303130383838383030303030383030323030303838383230383832303038383230383832303038383830303038383838323038303838303838383838303130303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303031313038")
    (hex 26880 "3838383030303032383830383030323838323032383830303030383830383838303038383230383230383838383038303838303838303030313130303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031313130383838383030323838383830303030383838303038383830303030383830383838323038383032383830383038383038383838303838303131313030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030313131")
    (hex 27136 "30383230383838383838383230383830383838303032383830303030383830383838383038383030383230383038383038383838303838323031303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031313130323030383838383232323032383830383838303030383838303038383230323838383838383032303030383030303038383838303838383031313030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030")
    (hex 27392 "303130303030383838383030303038383830323838383232303238383838323030303838383838383038303838383038383038303838303838383030313131313130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303131303030383838383230303838383230303238383838323032383832303030303838303838383038303238383030383032303238303838383830303030303031303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030")
    (hex 27648 "3030303031303032383838383830303238323030303030303030303030303030303030303238303038323038303038383832323030303232303238383230303637363031303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303031303038383838383230303030303030303030303030303030303030303030303030303030303038323032323030303030303030303032383030373737363031303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030")
    (hex 27904 "30303030303031313038383832303030303030303030303030303030303637373630303637363030303637363030303030303037373030303637363030303030363737303131303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303131313032323030303637373737373737363030303036373737373730303737373630303037373730303030303637373630363737373030303030303636303130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030")
    (hex 28160 "303030303030313131303030303036373737373737373737373630303037373737373730303737373737303037373630303036373037373030373737363030363736303030303130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303131303030363737373737373737373737373730303037373737373730303737373736303037373030303637373036363036373737303030373737373630303130303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030")
    (hex 28416 "3030303030303030313030303637373737373737373630303637373736303036373737373736303637373730303637363030303737373730303037373737303036373737373737303130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030313030363737373737373630303030303037373737303030373737373737303037373730303737303030363737373630363037373737303037373737373736303130303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030")
    (hex 28672 "30303030303030303031303030373737373737363030303030303037373737303030363737373737303037373730363737303036373737363036373037373737363037373737373630303130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031303036373737373737303030303030303037373736303030303030373737303037373730373737303637373630303037373037373737373037373737363030303130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030")
    (hex 28928 "303030303030303030303031303037373737373737303030303030303637373730363737373630363737363036373730373737373737373030303037373036373737373737373737303030313130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031303036373737373737303030303030363737373630373737373736303737373030373730373737373737373736303037373630373737373737373737303031313030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030")
    (hex 29184 "3030303030303030303030303031303036363036373737303030303036373737363036373737373737303737373630373730373737373737373737363037373730373737373737373737303131313030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031303030303030373737303036373737373736303037373737373737303737373737373730373737373737373737373036373730363730373737373737303131303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030")
    (hex 29440 "30303030303030303030303030303031313030303030373737373737373737373630303637373737373737303730363737373730363737373630303737373630373736303630363737373737363031313031313030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030313130303030373737373737373736303030303737373737373736303730303737373730303737373030303737373730373737303030303737373737373031313131313030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030")
    (hex 29696 "303030303030303030303030303030303030303130303036373737373737363030303630303737373737373030363736303637373736303637373030303737373730363737363030303637373737373630313131303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303130303037373737373630303030363730303737373737373037373737303037373737303030363030303737373736303737373030303037373737373736303131313030303030303030303030303030303030303030303030303030303030300a3030303030303030303030")
    (hex 29952 "3030303030303030303030303030303030303030303130303037373737373030303637373737373737373737373037373737303036373737363030303030303737373737303737373630303037373737373737363031313130303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031313130303037373737373030303737373737373737373737373037373737303030373737373630303030303737373736303637373736303036373737373737373630313130303030303030303030303030303030303030303030303030303030300a303030303030303030")
    (hex 30208 "30303030303030303030303030303030303030303131303030303637373737373630303737373737373737373737363036373737363030363737373737373730303737373630303037373737303030363737373737373736303130303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303130303036373737373737373737303737373737373737373737303030303637373030303737373737373630303737363030303036373736303030303730363737373636303130303030303030303030303030303030303030303030303030303030300a30303030303030")
    (hex 30464 "303030303030303030303030303030303030303030313130303637373737373737373736303737373737373737373736303030303030363030303637373736303030303636303030303030373030303030303630303030303030303130303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030313130303637373737373737373030303637373737373737373030303130303036363030303036363030303030303030303031303030363630303030303030303030303030313130303030303030303030303030303030303030303030303030303030300a3030303030")
    (hex 30720 "3030303030303030303030303030303030303030303030303130303036373737363037373030303037303030373030373030303131313036363030303030303030303030303030303131313030363630303131303030303030303030313030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030313131303030303730303036373030303036363030303030363030303131313030303030303030303030303031303030313130313131303030313131313131303030303031313030303030303030303030303030303030303030303030303030303030300a303030")
    (hex 30976 "30303030303030303030303030303030303030303030303030303131303030303730313030363031313036363030303030303031313131303131313131303030303030313131313131313031313131313131313030303030313131313130303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303031313131313030313131303031313130303030303131313131303030303030303031313030303131313131313131303031313030313130303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30")
    (hex 31232 "303030303030303030303030303030303030303030303030303030303031313131303131303030313130303031313131313030303030303030303030303030303131313030313130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 31488 "0a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 31744 "30300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 32000 "303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 32256 "3030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 32512 "30303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 32768 "303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 33024 "3030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633232323232323434323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323434343434323232323232303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 33280 "30303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332306334343434343434343434343434323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633230653234663434343434343434346634343230303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 33536 "303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633265323266666666666666346634666666343465303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332343234343434346634663466663434343434343230303030303030303030303030303030303030303030303030303030303030303030")
    (hex 33792 "3030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323434343234343434343434343434343434343434653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323234343434343234343434343434343434346530303030303030303030303030303030303030303030303030303030303030")
    (hex 34048 "30303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332343232653232323465323434343434343234653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323232303032656532303232346565343432653030303030303030303030303030303030303030303030303030303030")
    (hex 34304 "303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633232323432653030656565303265323265323232653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323234326666343465666634663434323232323265303030303030303030303030303030303030303030303030303030")
    (hex 34560 "3030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633234343266666666666666666632323239393265653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323063323430666666323038326666323432393965653232303030303030303030303030303030303030303030303030")
    (hex 34816 "30303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323234343430306666383866663232343234343232343265303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323434343465323637303036326534323434343434326565303030303030303030303030303030303030303030")
    (hex 35072 "303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063323234343434323836373634656632343434343432656530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306332323434343032323232323466663234343434343432303030303030303030303030303030303030303030")
    (hex 35328 "3030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633234343230303030303234343637363434343434326530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063343632363737373730303036363736343434326565303030303030303030303030303030303030")
    (hex 35584 "30303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633236363237373737383766653238383832343237656530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063333333323838323637373232383766663238323238323165373330303030303030303030303030303030")
    (hex 35840 "303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633133333335353535363737323737323666343662373333333133333365303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063633733353536323737373236363637323431623762303337633335316530303030303030303030303030")
    (hex 36096 "3030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063633763333532323637373631363636373131313131363663633733313531303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030633163633632383832323232313636363231313131363631313133333635316530303030303030303030")
    (hex 36352 "30303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063303533333032323232303231303636363230313631313131333333313530653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063303531333333313131313130353236363232363131313739333331333330653030303030303030")
    (hex 36608 "303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063353531363333333131313130353236363832323131393937333130333333653030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306335353136313933333131313130323836383832313131393333313036333365303030303030")
    (hex 36864 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030636262303030353535313639373933333030303032383838323030303333333036313535303030626231303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030636565313162376230303535353531393730333333333330303232323030303033333036313535353030623762")
    (hex 37120 "35313165653030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030306331656565333333333333333937353531363630333833333333333030303030333333383735353535333333333333336565653130303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633135653733333333333333333739353535353531313837383333623333333331333338373835356235333333")
    (hex 37376 "333333333337653531303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030636335333333393935363131333339353535363636363738363636623762333133333331333835623735313136353937393333333563653030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303063373333333336393536313133333535363630303030303030303037623030333333313333333337623531")
    (hex 37632 "3136353939363333333337653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633333333831303035353131353333363038313131313131313131313131333337653663373333333335313135353030303138333333653030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030306333373836303035353531313533333338373131313131313131313133333333653731376331303333")
    (hex 37888 "33313135353535303036383733653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633338383535303035353131303533333337383131316537313033333333363131653163313131393733313135353030303535383833653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633135353630313939353333303130333333383131653765333333333739313131313131313139")
    (hex 38144 "373933333335393931313036353531653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633135353031313937393333303130313333333131653333333333353937313131313131313131303133333339373931313130353531653030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030633138383131393333333133313637633333313333333333303030393030303131313131")
    (hex 38400 "3130363130313333333936313138383165653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030633331383738313333333131333333633731333333333330306237303030303030303031313036353333313133333333313837383133303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030306363373333333337653130306533336333333333333331336237623333333765303030")
    (hex 38656 "30363333333333303031653765333333333763653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030636363333333336531303030653031333333333336363333333333333333653733333333333333333365303030316565333333336363653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303065656565656565656565653065656565656565656565656565656565656565")
    (hex 38912 "656565656565656565306565656565656565656565653030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 39168 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 39424 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 39680 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303333303030303030303030303030303030303030303030303030303030303030303030303030303333")
    (hex 39936 "3330323232303333333032323030303030303230323030303030303030303030303030303030303030303032303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303330303032303230333330303232323030333330323232303333333030323230303333303030303030303330323032303030333030323030303030303230323030333330323230303033333032323230333333303032303030303030303030303030303030303030303030300a303030303030303030303030303030303030303033303030323032303330333030323030333030303032303033333330323032303330303030303030")
    (hex 40192 "33333330323032303333333030323030303030303230323033303330323032303330333030323030333330303032303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303330303032323230333330303032303030303330303230303330333032323230303033303030303033303030323032303330303030323030303030303230323033333330323032303333333030323030333030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303033333032303230333033303232323033333030303230303330333032303230333330303030")
    (hex 40448 "303033333330323232303333333032323230303030303032323033303030323230303330333030323030303333303032303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 40704 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 40960 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 41216 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 41472 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a0a5f5f7366785f5f0a623731303030323030303237353030323035303032373530303230353061323735303032373530")
    (hex 41728 "3032303530303237353030323035303032373530613237353030323735306332373530303237353061323735303032373530303237353030323035303032373530303230353061323735303032373530303230353030323735303032303530303237353061323735303032373530633237353030323735306132373530303237350a623731303030323031386137353138613030313861373531386130303138613735313861303030636137303231613735323261303032316137353138613030313561373032316135303231613435313561373032306137353138613030323061373531386130303135613730323061353032306134353135613730323061")
    (hex 41984 "3735313861303032306137353138613030313561373031626136303162613735316261363031626137350a3031303130303030303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237303030323730303032373030303237300a3030303130303030326430353033323035303238303530323330353031653035303139303530313830353031")
    (hex 42240 "373035303137303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a6237313030303230303032373530303230353030323735303032303530613237353030323735303032303530303237353030323035303032373530613237353030323735306332373530303237353061323735303032373530303237353030323030303032303030303230303061323030303032303030303230303030323030303032")
    (hex 42496 "303030303230303061323030303032303030633230303030323030306132303030303230300a3031303830303030323930353032643035303330303530323930343032643034303330303430323930333032643033303330303330323930323032643032303330303230323930313032643031303330303130323930313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 42752 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 43008 "30303030303030303030303030303030303030303030303030303030303030300a3031313030303030306330373330303030333063363030303030303030633637333030303033306330373330303030333063363030303030303030633037333030303033306336373330303030333131363733303030303330633037333030303033306336303030303030303063363733303030303330633037333030303033306336303030303030303063303733303030303330633637333030303033313136373330303030330a303131303030303030303632333030303030306336323330303030303138363233303030303030303632333030303033303036323330")
    (hex 43264 "3030303030633632333030303030313836323330303030303030363233303030303030303632333030303030306336323330303030303138363233303030303030303632333030303033303036323330303030303063363233303030303031383632333030303030303036323330303030300a303131303030303030633037333030303033306336303030303030303063363733303030303330633037333030303033306336303030303030303063303733303030303330633637333030303030306330373331313637333063303733303030303330633630303030303030306336373330303030333063303733303030303330633630303030303030306330")
    (hex 43520 "3733303030303330633637333030303033306330373331313637330a3031313030303230323436333032343632303234363230323436303032303630303230363030323036303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031313030303030306330373330303030333063363030303030303030633637333030303033306330373330303030333063363030303030303030")
    (hex 43776 "633037333030303033306336373330303030333131363733303030303330633037333030303033306330303030303030303063363733303030303330633030303030303033306330373330303030303063303030303030303330633637333030303033306330303030303030330a3031313030303030303036323330303630303063363233303036303031383632333030363030303036323330303630303030363233303036303030633632333030363030313836323330303630303030363233303036303030303632333030363233306336323330303632333138363233303036323330303632333030363233303036323330303632333063363233303036")
    (hex 44032 "323331383632333030363233303036323330303632330a6431313030303030313637343031363734303136373430313637343031363734303136373430313637343031363734303136373330313637333031363733303136373330313637333031363733303136373330313637333031363732303136373230313637323031363732303136373230313637323031363732303136373230313637313031363731303136373130313637313031363731303136373130313637313031363731300a64313130303030303136373430313637343031363734303136373430313637343031363734303136373430313637343031363733303136373330313637333031")
    (hex 44288 "36373330313637323031363732303136373230313637313032323730303232373030323237303032323730303232373030323237303032323730303232373030323237303032323730303232373030323237303032323730303232373030323237303032323730300a64313130303030303166373430316637343031663733303166373330316637303031663730303163373430316337343031633733303163373330316337323031633732303163373030316337303031623734303162373430316237343031623734303162373330316237333031623733303162373330316237323031623732303162373230316237323031623731303162373130316237")
    (hex 44544 "31303162373130316237303031623730300a5f5f6d757369635f5f0a30302030383030343930390a30302030633034346430640a30312030383030343930390a30302030383030343930390a30302030383030343930390a30302030633034346430640a30302030613031303935300a30302030613031303935300a30302030613031303935300a30322030613031303935300a0a")))
