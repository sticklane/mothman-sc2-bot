#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : BunBun Samurai (bunbunsamurai-12.p8)
;; Source ROM : assets/roms/pico/bunbunsamurai-12.p8 (106453 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "jelpi")
  (title "BunBun Samurai (bunbunsamurai-12.p8)")
  (rom-source "pico/bunbunsamurai-12.p8")
  (rom-bytes 106453)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label gff map sfx music))
    (lua-line-count 2527)
    (lifted-function-count 165)
    (gfx-row-count 128)
    (map-row-count 32)
    (gff-row-count 2)
    (sfx-row-count 64)
    (music-row-count 65))
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
    (lifted-functions (_draw _init _update60 a_alert_checkforwindup a_anim_set a_anim_update a_attack a_deviate a_doflipx a_fly a_move_angle a_random_turn a_set_invuln_flash add_to_people alert_class attack_reset attack_target attempt_deflect_target cam_pos check_for_footsteps combo constrain_to_borders constrain_to_screen copy_screen_to_mem damage dealt_damage del_from_people draw draw_character draw_class emotion_add emotion_set_from_count emotion_update explode fd fire_arrow fly_reset frnd frnda fu game_pause get_angle_from_input get_dir_to_player get_direction_to_turn get_flipx_from_angle get_gen_coords get_rebound_angle_speed get_yboboffset handle_impact handle_impact_class handle_impact_death handle_slash_entity_impact handle_slash_recovery init int_cols is_level_active is_near_objs is_timed_mode kill kill_class level_create level_end level_end_bad level_end_player_died level_end_villager_died level_end_win m_arrow m_bodypart m_cam m_emotion m_enemy m_enemy_archer m_enemy_bomber m_enemy_boss m_enemy_furniture m_enemy_random m_enemy_seeker m_enemy_villager m_enemy_wander m_food m_object m_part_angle m_part_blood m_part_bloodsplash m_part_bomb_spark m_part_circle m_part_impact m_part_sprite m_player m_splat m_step m_textfloat m_transition_splatter move nearest_angle paste_screen_from_mem printc printc_o printsprite randc reset_game reset_level rndbool save_score score_add set_cam_pos set_outline shake slash slash_target sort_by_y split_entity table_clear touch_class transition_level update update_base update_class update_weather wrap))
    (pico8-api-calls (abs add all atan2 btn btnp camera circfill cls cos del flr foreach line map max memcpy mget mid min mset pal print pset rect rectfill rnd sfx sin spr))
    (structured-loops 15)
    (structured-conditionals 102)
    (lifted-state-machines 2)
    (lifted-high-level-idioms 6)
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 32)
    (active-sfx-lifted 32)
    (active-music-lifted 64))
  (pico8-state-machines
    (def-pico-state-machine pico8_lifecycle_fsm #:hooks (_init _update _draw) #:update-states (_update60 a_anim_update a_move_angle check_for_footsteps emotion_update game_pause get_dir_to_player level_end_player_died) #:draw-states (_draw draw draw_character draw_class m_part_sprite printsprite))
    (def-pico-state-machine pico8_entity_dispatch_fsm #:mechanism foreach-all-iterator #:registered-handlers (_draw _init _update60 a_alert_checkforwindup a_anim_set a_anim_update a_attack a_deviate a_doflipx a_fly)))
  (high-level-idioms
    (idiom-pico8-entity-iterator #:apis (foreach all add del) #:call-sites 65)
    (idiom-pico8-tilemap-collision #:apis (mget fget map) #:call-sites 5)
    (idiom-pico8-sprite-batch-render #:apis (spr sspr pal palt cls) #:call-sites 56)
    (idiom-pico8-fixed-point-physics #:apis (flr sin cos abs min max) #:call-sites 65)
    (idiom-pico8-input-poll #:apis (btn btnp) #:call-sites 11)
    (idiom-pico8-audio-trigger #:apis (sfx music) #:call-sites 28))
  ;; --- 4. Symbolic MMIO Cross-Reference, State Machines, Idioms & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function
      (name frnd)
      (params (n))
      (line-range (13 15))
      (api-calls (flr rnd))
      (called-functions ())
      (structured-ast
        (return-expr "flr(rnd(n))"))
      (decompiled-pseudo-code
        (return "flr(rnd(n))"))
      (body-lines
        "function frnd(n)"
        "\treturn flr(rnd(n))"
        "end"))
    (def-pico-function
      (name frnda)
      (params (n o))
      (line-range (17 20))
      (api-calls ())
      (called-functions (frnd))
      (structured-ast
        (return-expr "frnd(n)+addval"))
      (decompiled-pseudo-code
        (set! addval "o or 1")
        (return "frnd(n)+addval"))
      (body-lines
        "function frnda(n, o)"
        "\tlocal addval = o or 1"
        "\treturn frnd(n)+addval"
        "end"))
    (def-pico-function
      (name randc)
      (params (chance))
      (line-range (22 26))
      (api-calls ())
      (called-functions (frnd))
      (structured-ast
        (if-cond "frnd(100")
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! c "chance or 50")
        (when "frnd(100) < c")
        (return "true"))
      (body-lines
        "function randc(chance)"
        "\tlocal c = chance or 50"
        "\tif frnd(100) < c then"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name wrap)
      (params (value min max))
      (line-range (30 37))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "value < min")
        (return-expr "max")
        (return-expr "min")
        (return-expr "value"))
      (decompiled-pseudo-code
        (when "value < min")
        (return "max")
        (when "value > max")
        (return "min")
        (return "value"))
      (body-lines
        "function wrap(value, min, max)"
        "\tif value < min then"
        "\t\treturn max"
        "\telseif value > max then"
        "\t\treturn min"
        "\telse"
        "\t\treturn value"
        "\tend"))
    (def-pico-function
      (name table_clear)
      (params (t))
      (line-range (40 43))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "i=0, count"))
      (decompiled-pseudo-code
        (set! count "#t")
        (for-range i "0" "count"))
      (body-lines
        "function table_clear(t)"
        "\tlocal count = #t"
        "\tfor i=0, count do t[i]=nil end"
        "end"))
    (def-pico-function
      (name copy_screen_to_mem)
      (params ())
      (line-range (45 50))
      (api-calls (memcpy))
      (called-functions ())
      (structured-ast
        (seq-block 6))
      (decompiled-pseudo-code
        (call memcpy "0x1800, 0x6000, 0x0800")
        (call memcpy "0x4300, 0x6800, 0x1800"))
      (body-lines
        "function copy_screen_to_mem()"
        "\t-- half the map/lower sprite memory area"
        "\tmemcpy(0x1800, 0x6000, 0x0800)"
        "\t-- almost all general use memory"
        "\tmemcpy(0x4300, 0x6800, 0x1800)"
        "end"))
    (def-pico-function
      (name paste_screen_from_mem)
      (params ())
      (line-range (52 55))
      (api-calls (memcpy))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (call memcpy "0x6000, 0x1800, 0x0800")
        (call memcpy "0x6800, 0x4300, 0x1800"))
      (body-lines
        "function paste_screen_from_mem()"
        "\tmemcpy(0x6000, 0x1800, 0x0800)"
        "\tmemcpy(0x6800, 0x4300, 0x1800)"
        "end"))
    (def-pico-function
      (name printc_o)
      (params (str y col outcol x))
      (line-range (57 61))
      (api-calls ())
      (called-functions (printc))
      (structured-ast
        (for-loop "i=-1,1")
        (for-loop "j=-1,1"))
      (decompiled-pseudo-code
        (for-range i "-1" "1")
        (for-range j "-1" "1")
        (call printc "str, y+j, outcol or 2, (x or 64)+i"))
      (body-lines
        "function printc_o(str, y, col, outcol, x) -- print a centered string with a black outline"
        "\tfor i=-1,1 do"
        "\t \tfor j=-1,1 do"
        "\t   \tprintc(str, y+j, outcol or 2, (x or 64)+i)"
        "\t \tend"))
    (def-pico-function
      (name printc)
      (params (str y col x))
      (line-range (66 68))
      (api-calls (print))
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (call print "str, (x or 64)-#str*2, y, col or 7"))
      (body-lines
        "function printc(str, y, col, x)"
        "\tprint(str, (x or 64)-#str*2, y, col or 7)"
        "end"))
    (def-pico-function
      (name printsprite)
      (params (str y color))
      (line-range (71 81))
      (api-calls (all flr pal spr))
      (called-functions ())
      (structured-ast
        (for-loop "i=1, #str")
        (for-loop "j in all(g_alphabet_sprites)")
        (if-cond "letter == j"))
      (decompiled-pseudo-code
        (call pal "7, color")
        (for-range i "1" "#str")
        (set! |letter, whichalpha| "sub(str,i,i), -1")
        (foreach j "g_alphabet_sprites")
        (+= whichalpha "1")
        (when "letter == j")
        (call spr "131 + flr(whichalpha/9)*16 + whichalpha % 9, 64-(#str*8)/2 + (i-1)*8, y"))
      (body-lines
        "function printsprite(str, y, color)"
        "\tpal(7, color)"
        "\tfor i=1, #str do"
        ""
        "\t\tlocal letter, whichalpha = sub(str,i,i), -1"
        "\t\tfor j in all(g_alphabet_sprites) do"
        "\t\t\twhichalpha += 1"
        "\t\t\tif letter == j then"
        "\t\t\t\tspr(131 + flr(whichalpha/9)*16 + whichalpha % 9, 64-(#str*8)/2 + (i-1)*8, y)"
        "\t\t\t\tbreak"
        "\t\t\tend"))
    (def-pico-function
      (name set_outline)
      (params ())
      (line-range (87 89))
      (api-calls (pal))
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (call pal "2, g_color_outline"))
      (body-lines
        "function set_outline()"
        "\tpal(2, g_color_outline)"
        "end"))
    (def-pico-function
      (name m_textfloat)
      (params (x y text col_main col_sec))
      (line-range (91 101))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (seq-block 11))
      (decompiled-pseudo-code
        (set! x "x,")
        (set! y "y,")
        (set! text "text,")
        (set! col_main "col_main or 7,")
        (set! col_sec "col_sec or 5,")
        (set! dur "30,")
        (set! dur_orig "30,"))
      (body-lines
        "function m_textfloat(x,y, text, col_main, col_sec)"
        "\tadd(list_parts_front,"
        "\t{"
        "\t\tx=x,"
        "\t\ty=y,"
        "\t\ttext=text,"
        "\t\tcol_main=col_main or 7,"
        "\t\tcol_sec=col_sec or 5,"
        "\t\tdur=30,"
        "\t\tdur_orig=30,"
        ""))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (102 106))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.dur < self.dur_orig/3"))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (set! color "self.col_main")
        (when "self.dur < self.dur_orig/3")
        (set! color "self.col_sec"))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tlocal color = self.col_main"
        "\t\t\tif self.dur < self.dur_orig/3 then"
        "\t\t\t\tcolor = self.col_sec"
        "\t\t\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (110 116))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "self.dur == 0"))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (-= self.dur "1")
        (when "self.dur == 0")
        (call del "list_parts_front, self")
        (-= self.y ".3"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tself.dur-=1"
        "\t\t\tif self.dur == 0 then"
        "\t\t\t\tdel(list_parts_front, self)"
        "\t\t\telse"
        "\t\t\t\tself.y -= .3"
        "\t\t\tend"))
    (def-pico-function
      (name a_set_invuln_flash)
      (params (self))
      (line-range (121 125))
      (api-calls (pal))
      (called-functions ())
      (structured-ast
        (if-cond "self.invuln_frames > 0 and self.invuln_frames % 5 < 3")
        (for-loop "i=1,15"))
      (decompiled-pseudo-code
        (when "self.invuln_frames > 0 and self.invuln_frames % 5 < 3")
        (for-range i "1" "15")
        (call pal "i, 2"))
      (body-lines
        "function a_set_invuln_flash(self)"
        "\tif self.invuln_frames > 0 and self.invuln_frames % 5 < 3 then"
        "\t\tfor i=1,15 do"
        "\t\t\tpal(i, 2)"
        "\t\tend"))
    (def-pico-function
      (name is_near_objs)
      (params (obj1 obj2 range))
      (line-range (131 134))
      (api-calls (abs))
      (called-functions ())
      (structured-ast
        (if-cond "abs(obj1.x-obj2.x")
        (return-expr "true"))
      (decompiled-pseudo-code
        (when "abs(obj1.x-obj2.x) <= range and abs(obj1.y-obj2.y) <= range")
        (return "true"))
      (body-lines
        "function is_near_objs(obj1, obj2, range)"
        "\tif abs(obj1.x-obj2.x) <= range and abs(obj1.y-obj2.y) <= range then"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name int_cols)
      (params (e1 e2 buffer))
      (line-range (138 141))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "e1.just_spawned or e2.just_spawned")
        (return-expr "false"))
      (decompiled-pseudo-code
        (when "e1.just_spawned or e2.just_spawned")
        (return "false"))
      (body-lines
        "function int_cols(e1, e2, buffer)"
        "\tif e1.just_spawned or e2.just_spawned then"
        "\t\treturn false"
        "\tend"))
    (def-pico-function
      (name m_part_blood)
      (params (part_details duration))
      (line-range (159 162))
      (api-calls ())
      (called-functions (frnda m_part_angle))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! |part_details[6]| "duration or frnda(10, 50)")
        (call m_part_angle "part_details, .65, 8, g_color_blood_burn"))
      (body-lines
        "function m_part_blood(part_details, duration)"
        "\tpart_details[6] = duration or frnda(10, 50)"
        "\tm_part_angle(part_details, .65, 8, g_color_blood_burn)"
        "end"))
    (def-pico-function
      (name m_part_angle)
      (params (part_details frict color color_sec layer))
      (line-range (164 180))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 17))
      (decompiled-pseudo-code
        (set! size "part_details[1]-1,")
        (set! x "part_details[2],")
        (set! y "part_details[3],")
        (set! angle "part_details[4],")
        (set! speed_move "part_details[5],")
        (set! duration "part_details[6],")
        (set! frict "frict,")
        (set! color "color,")
        (set! color_sec "color_sec or color,")
        (set! layer "layer or 0,")
        (set! time "0,"))
      (body-lines
        "function m_part_angle(part_details, frict, color, color_sec, layer)"
        ""
        "\tlocal p ="
        "\t{"
        "\t\tsize=part_details[1]-1,"
        "\t\tx=part_details[2],"
        "\t\ty=part_details[3],"
        "\t\tangle=part_details[4],"
        "\t\tspeed_move=part_details[5],"
        "\t\tduration=part_details[6],"
        "\t\tfrict=frict,"
        "\t\tcolor=color,"
        "\t\tcolor_sec=color_sec or color,"
        "\t\tlayer=layer or 0,"
        ""
        "\t\ttime=0,"
        ""))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (181 185))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.time > self.duration *.75"))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (set! |color, s2| "self.color, self.size/2")
        (when "self.time > self.duration *.75")
        (set! color "self.color_sec"))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tlocal color, s2 = self.color, self.size/2"
        "\t\t\tif self.time > self.duration *.75 then"
        "\t\t\t\tcolor = self.color_sec"
        "\t\t\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (193 201))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "self.time > self.duration")
        (if-cond "self.layer == 1"))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (when "self.time > self.duration")
        (when "self.layer == 1")
        (call del "list_parts_back, self")
        (when "self.layer == 2")
        (call del "list_parts_front, self")
        (call del "list_parts_blood, self"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tif self.time > self.duration then"
        "\t\t\t\tif self.layer == 1 then"
        "\t\t\t\t\tdel(list_parts_back, self)"
        "\t\t\t\telseif self.layer == 2 then"
        "\t\t\t\t\tdel(list_parts_front, self)"
        "\t\t\t\telse"
        "\t\t\t\t\tdel(list_parts_blood, self)"
        "\t\t\t\tend"))
    (def-pico-function
      (name m_part_sprite)
      (params (frame x y dy col col_sec duration flipx is_front))
      (line-range (222 239))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 18))
      (decompiled-pseudo-code
        (set! x "x,")
        (set! y "y,")
        (set! frame "frame,")
        (set! col "col,")
        (set! col_sec "col_sec or col,")
        (set! duration "duration,")
        (set! flipx "flipx or false,")
        (set! is_front "is_front or false,")
        (set! time "0,")
        (set! dx "0,")
        (set! dy "dy,")
        (set! ddy "0,"))
      (body-lines
        "function m_part_sprite(frame, x,y, dy, col, col_sec, duration, flipx, is_front)"
        ""
        "\tlocal p ="
        "\t{"
        "\t\tx=x,"
        "\t\ty=y,"
        "\t\tframe=frame,"
        "\t\tcol=col,"
        "\t\tcol_sec=col_sec or col,"
        "\t\tduration=duration,"
        "\t\tflipx=flipx or false,"
        "\t\tis_front=is_front or false,"
        ""
        "\t\ttime=0,"
        "\t\tdx=0,"
        "\t\tdy=dy,"
        "\t\tddy=0,"
        ""))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (240 245))
      (api-calls (pal))
      (called-functions ())
      (structured-ast
        (if-cond "self.time < self.duration *.75"))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (when "self.time < self.duration *.75")
        (call pal "7,self.col")
        (call pal "7,self.col_sec"))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tif self.time < self.duration *.75 then"
        "\t\t\t\tpal(7,self.col)"
        "\t\t\telse"
        "\t\t\t\tpal(7,self.col_sec)"
        "\t\t\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (250 252))
      (api-calls ())
      (called-functions (update_base))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (call self:update_base ""))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tself:update_base()"
        "\t\tend,"))
    (def-pico-function
      (name update_base)
      (params (self))
      (line-range (254 260))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "self.time > self.duration")
        (if-cond "self.is_front"))
      (decompiled-pseudo-code
        (set! update_base "function(self)")
        (when "self.time > self.duration")
        (when "self.is_front")
        (call del "list_parts_front, self")
        (call del "list_parts_back, self"))
      (body-lines
        "\t\tupdate_base=function(self)"
        "\t\t\tif self.time > self.duration then"
        "\t\t\t\tif self.is_front then"
        "\t\t\t\t\tdel(list_parts_front, self)"
        "\t\t\t\telse"
        "\t\t\t\t\tdel(list_parts_back, self)"
        "\t\t\t\tend"))
    (def-pico-function
      (name m_part_bomb_spark)
      (params (x y))
      (line-range (277 281))
      (api-calls ())
      (called-functions (randc))
      (structured-ast
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! |color, color_second| "10, 9")
        (when "randc()")
        (set! |color, color_second| "7, 10"))
      (body-lines
        "function m_part_bomb_spark(x, y)"
        "\tlocal color, color_second = 10, 9"
        "\tif randc() then"
        "\t\tcolor, color_second = 7, 10"
        "\tend"))
    (def-pico-function
      (name m_part_circle)
      (params (x y size duration color color_sec layer))
      (line-range (291 293))
      (api-calls ())
      (called-functions (m_part_angle))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! p "m_part_angle({size, x, y, 0, 0, duration}, 0, color, color_sec, layer)"))
      (body-lines
        "function m_part_circle(x,y, size, duration, color, color_sec, layer)"
        ""
        "\tlocal p = m_part_angle({size, x, y, 0, 0, duration}, 0, color, color_sec, layer)"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (294 298))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.time > self.duration * .75"))
      (decompiled-pseudo-code
        (set! p.draw "function(self)")
        (set! color "self.color")
        (when "self.time > self.duration * .75")
        (set! color "self.color_sec"))
      (body-lines
        "\tp.draw=function(self)"
        "\t\tlocal color = self.color"
        "\t\tif self.time > self.duration * .75 then"
        "\t\t\tcolor = self.color_sec"
        "\t\tend"))
    (def-pico-function
      (name m_part_bloodsplash)
      (params (x y angle))
      (line-range (303 312))
      (api-calls (rnd))
      (called-functions ())
      (structured-ast
        (for-loop "i=0,36")
        (if-cond "i > 30"))
      (decompiled-pseudo-code
        (for-range i "0" "36")
        (set! |size, xoff, yoff, angleoff,dur| "1, rnd(4), rnd(4), rnd(.2), rnd(8)")
        (when "i > 30")
        (set! dur "rnd(1)")
        (set! size "2")
        (when "i > 15")
        (set! dur "rnd(4)"))
      (body-lines
        "function m_part_bloodsplash(x,y,angle)"
        ""
        "\tfor i=0,36 do"
        "\t\tlocal size, xoff, yoff, angleoff,dur=1, rnd(4), rnd(4), rnd(.2), rnd(8)"
        "\t\tif i > 30 then"
        "\t\t\tdur=rnd(1)"
        "\t\t\tsize=2"
        "\t\telseif i > 15 then"
        "\t\t\tdur=rnd(4)"
        "\t\tend"))
    (def-pico-function
      (name m_part_impact)
      (params (entity size))
      (line-range (318 320))
      (api-calls ())
      (called-functions (m_part_circle))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (call m_part_circle "entity.x, entity.y, size or 7, 4, 10, 9, 1"))
      (body-lines
        "function m_part_impact(entity,size)"
        "\tm_part_circle(entity.x, entity.y, size or 7, 4, 10, 9, 1)"
        "end"))
    (def-pico-function
      (name handle_slash_recovery)
      (params (speed))
      (line-range (322 326))
      (api-calls (rnd))
      (called-functions (randc))
      (structured-ast
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! dir "rnd(.125)")
        (when "randc()")
        (set! dir "0-dir"))
      (body-lines
        "function handle_slash_recovery(speed)"
        "\tlocal dir = rnd(.125)"
        "\tif randc() then"
        "\t\tdir = 0-dir"
        "\tend"))
    (def-pico-function
      (name handle_slash_entity_impact)
      (params (target))
      (line-range (333 339))
      (api-calls ())
      (called-functions (game_pause m_part_bloodsplash shake))
      (structured-ast
        (if-cond "not target.is_furniture"))
      (decompiled-pseudo-code
        (call cam:shake ".1, 3")
        (call game_pause "2, 0")
        (when "not target.is_furniture")
        (call m_part_bloodsplash "target.x, target.y, p1.slash_angle"))
      (body-lines
        "function handle_slash_entity_impact(target)"
        ""
        "\tcam:shake(.1, 3)"
        "  game_pause(2, 0)"
        "\tif not target.is_furniture then"
        "\t\tm_part_bloodsplash(target.x, target.y, p1.slash_angle)"
        "\tend"))
    (def-pico-function
      (name score_add)
      (params (entity score))
      (line-range (345 350))
      (api-calls (flr min sfx))
      (called-functions ())
      (structured-ast
        (if-cond "score > 0"))
      (decompiled-pseudo-code
        (when "score > 0")
        (call sfx "min(26+flr(score/1), 31)")
        (call sfx "32"))
      (body-lines
        "function score_add(entity, score)"
        "\tif score > 0 then"
        "\t\tsfx(min(26+flr(score/1), 31))"
        "\telse"
        "\t\tsfx(32)"
        "\tend"))
    (def-pico-function
      (name attempt_deflect_target)
      (params (target))
      (line-range (367 382))
      (api-calls (abs rnd sfx))
      (called-functions (m_part_circle randc))
      (structured-ast
        (if-cond "abs(p1.slash_angle - reverse_angle")
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! reverse_angle "abs(target.angle+.5)%1")
        (when "abs(p1.slash_angle - reverse_angle) < .25")
        (call sfx "8")
        (call m_part_circle "target.x, target.y, 6, 10, 7, 5, 1")
        (set! t_dir "rnd(.125)")
        (when "randc()")
        (set! t_dir "0 - t_dir"))
      (body-lines
        "function attempt_deflect_target(target)"
        ""
        "\tlocal reverse_angle = abs(target.angle+.5)%1"
        ""
        "\tif abs(p1.slash_angle - reverse_angle) < .25 then"
        ""
        "\t\tsfx(8)"
        "\t\tm_part_circle(target.x, target.y, 6, 10, 7, 5, 1)"
        ""
        "\t\ttarget.is_flying, target.is_flying_impactable, target.windup_time_rem, target.attack_time_rem, target.fly_speed ="
        "\t\ttrue, false, 0, 0, 2"
        ""
        "\t\tlocal t_dir = rnd(.125)"
        "\t\tif randc() then"
        "\t\t\tt_dir = 0 - t_dir"
        "\t\tend"))
    (def-pico-function
      (name combo)
      (params (entity target))
      (line-range (394 402))
      (api-calls (sfx))
      (called-functions (frnda handle_impact_death m_part_bloodsplash))
      (structured-ast
        (if-cond "not entity.is_furniture"))
      (decompiled-pseudo-code
        (set! entity.was_counted_for_combo "true")
        (call sfx "frnda(2, 21)")
        (call handle_impact_death "entity, target")
        (when "not entity.is_furniture")
        (call m_part_bloodsplash "target.x, target.y, entity.angle"))
      (body-lines
        "function combo(entity, target)"
        "\tentity.was_counted_for_combo = true"
        ""
        "\tsfx(frnda(2, 21))"
        "\thandle_impact_death(entity, target)"
        ""
        "\tif not entity.is_furniture then"
        "\t\tm_part_bloodsplash(target.x, target.y, entity.angle)"
        "\tend"))
    (def-pico-function
      (name slash_target)
      (params (target))
      (line-range (419 426))
      (api-calls (sfx))
      (called-functions (a_anim_set handle_impact handle_slash_entity_impact))
      (structured-ast
        (seq-block 8))
      (decompiled-pseudo-code
        (call sfx "25")
        (set! |target.fly_speed, target.angle| "3, p1.slash_angle")
        (call target:handle_impact "")
        (call handle_slash_entity_impact "target")
        (call a_anim_set "p1, \"attack\""))
      (body-lines
        "function slash_target(target)"
        ""
        "\tsfx(25)"
        "\ttarget.fly_speed, target.angle = 3, p1.slash_angle"
        "\ttarget:handle_impact()"
        "\thandle_slash_entity_impact(target)"
        "\ta_anim_set(p1, \"attack\")"
        "end"))
    (def-pico-function
      (name a_anim_update)
      (params (entity anim_set tick_multiplier))
      (line-range (428 431))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "tick_multiplier == nil"))
      (decompiled-pseudo-code
        (when "tick_multiplier == nil")
        (set! tick_multiplier "1"))
      (body-lines
        "function a_anim_update(entity, anim_set, tick_multiplier)"
        "\tif tick_multiplier == nil then"
        "\t\ttick_multiplier = 1"
        "\tend"))
    (def-pico-function
      (name a_anim_set)
      (params (entity anim))
      (line-range (444 448))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "(anim==entity.curanim")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! |entity.animtick, entity.curanim, entity.curframe| "character_anims[anim].ticks, anim, 1"))
      (body-lines
        "function a_anim_set(entity, anim)"
        "\tif(anim==entity.curanim)return"
        ""
        "\tentity.animtick, entity.curanim, entity.curframe = character_anims[anim].ticks, anim, 1"
        "end"))
    (def-pico-function
      (name a_doflipx)
      (params (entity))
      (line-range (450 458))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "angle == .25 or angle == .75")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! angle "entity.angle")
        (when "angle == .25 or angle == .75")
        (return "")
        (when "angle > .25 and angle < .75")
        (set! entity.flipx "true")
        (set! entity.flipx "false"))
      (body-lines
        "function a_doflipx(entity)"
        "\tlocal angle = entity.angle"
        "\tif angle == .25 or angle == .75 then"
        "\t\treturn"
        "\telseif angle > .25 and angle < .75 then"
        "\t\tentity.flipx = true"
        "\telse"
        "\t\tentity.flipx = false"
        "\tend"))
    (def-pico-function
      (name constrain_to_screen)
      (params (obj))
      (line-range (461 463))
      (api-calls ())
      (called-functions (constrain_to_borders))
      (structured-ast
        (return-expr "constrain_to_borders(obj, g_level_screen_buffer+4, g_level_scree"))
      (decompiled-pseudo-code
        (return "constrain_to_borders(obj, g_level_screen_buffer+4, g_level_screen_buffer+4, 124-g_level_screen_buffer, 124-g_level_screen_buffer)"))
      (body-lines
        "function constrain_to_screen(obj)"
        "\treturn constrain_to_borders(obj, g_level_screen_buffer+4, g_level_screen_buffer+4, 124-g_level_screen_buffer, 124-g_level_screen_buffer)"
        "end"))
    (def-pico-function
      (name constrain_to_borders)
      (params (obj bor_x1 bor_y1 bor_x2 bor_y2))
      (line-range (465 472))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "x < bor_x1"))
      (decompiled-pseudo-code
        (set! |was_constrained, x, y| "false, obj.x, obj.y")
        (when "x < bor_x1")
        (set! |x, was_constrained| "bor_x1, true")
        (when "x > bor_x2")
        (set! |x, was_constrained| "bor_x2, true"))
      (body-lines
        "function constrain_to_borders(obj, bor_x1, bor_y1, bor_x2, bor_y2)"
        ""
        "\tlocal was_constrained, x, y = false, obj.x, obj.y"
        "\tif x < bor_x1 then"
        "\t\tx, was_constrained = bor_x1, true"
        "\telseif x > bor_x2 then"
        "\t\tx, was_constrained = bor_x2, true"
        "\tend"))
    (def-pico-function
      (name game_pause)
      (params (duration))
      (line-range (482 484))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! game_pause_timer "duration"))
      (body-lines
        "function game_pause(duration)"
        "\tgame_pause_timer = duration"
        "end"))
    (def-pico-function
      (name handle_impact_death)
      (params (entity target))
      (line-range (486 494))
      (api-calls ())
      (called-functions (m_part_bloodsplash split_entity))
      (structured-ast
        (if-cond "not entity.is_furniture and not entity.is_armored")
        (if-cond "target.is_heavy")
        (if-cond "not target.is_bloody"))
      (decompiled-pseudo-code
        (when "not entity.is_furniture and not entity.is_armored")
        (call split_entity "entity, (entity.angle+.5)%1")
        (call m_part_bloodsplash "target.x, target.y, entity.angle")
        (when "target.is_heavy")
        (when "not target.is_bloody")
        (+= target.sprite "16")
        (set! target.is_bloody "true"))
      (body-lines
        "function handle_impact_death(entity, target)"
        "\tif not entity.is_furniture and not entity.is_armored then"
        "\t\tsplit_entity(entity, (entity.angle+.5)%1)"
        "\t\tm_part_bloodsplash(target.x, target.y, entity.angle)"
        "\t\tif target.is_heavy then"
        "\t\t\tif not target.is_bloody then"
        "\t\t\t\ttarget.sprite += 16"
        "\t\t\t\ttarget.is_bloody = true"
        "\t\t\tend"))
    (def-pico-function
      (name fly_reset)
      (params (entity))
      (line-range (510 513))
      (api-calls ())
      (called-functions (get_dir_to_player))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (nop))
      (body-lines
        "function fly_reset(entity)"
        "\tentity.fly_speed, entity.is_flying, entity.is_flying_impactable, entity.angle, entity.score_multiplier ="
        "\t0, false, false, get_dir_to_player(entity), 1"
        "end"))
    (def-pico-function
      (name attack_reset)
      (params (entity))
      (line-range (515 518))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (nop))
      (body-lines
        "function attack_reset(entity)"
        "\tentity.attack_time_rem, entity.recovery_time_rem, entity.time_between_attacks_rem ="
        "\t0, entity.recovery_time, entity.time_between_attacks+entity.recovery_time"
        "end"))
    (def-pico-function
      (name a_attack)
      (params (entity))
      (line-range (520 527))
      (api-calls (sfx))
      (called-functions (a_move_angle attack_reset constrain_to_screen))
      (structured-ast
        (if-cond "constrain_to_screen(entity"))
      (decompiled-pseudo-code
        (-= entity.attack_time_rem "1")
        (call a_move_angle "entity, 4")
        (when "constrain_to_screen(entity)")
        (call sfx "20")
        (call attack_reset "entity"))
      (body-lines
        "function a_attack(entity)"
        ""
        "\tentity.attack_time_rem -= 1"
        "\ta_move_angle(entity, 4)"
        "\tif constrain_to_screen(entity) then"
        "\t\tsfx(20)"
        "\t\tattack_reset(entity)"
        "\tend"))
    (def-pico-function
      (name a_fly)
      (params (entity))
      (line-range (534 543))
      (api-calls ())
      (called-functions (a_move_angle fly_reset))
      (structured-ast
        (if-cond "entity.fly_speed <= .1"))
      (decompiled-pseudo-code
        (call a_move_angle "entity, entity.fly_speed")
        (*= entity.fly_speed ".95")
        (set! was_reset "false")
        (when "entity.fly_speed <= .1")
        (call fly_reset "entity")
        (set! was_reset "true"))
      (body-lines
        "function a_fly(entity)"
        "\ta_move_angle(entity, entity.fly_speed)"
        "\tentity.fly_speed *= .95"
        ""
        "\tlocal was_reset = false"
        ""
        "  if entity.fly_speed <= .1 then"
        "\t\tfly_reset(entity)"
        "\t\twas_reset = true"
        "  end"))
    (def-pico-function
      (name a_move_angle)
      (params (entity speed))
      (line-range (566 569))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "not speed"))
      (decompiled-pseudo-code
        (when "not speed")
        (set! speed "entity.speed_move"))
      (body-lines
        "function a_move_angle(entity, speed)"
        "\tif not speed then"
        "\t\tspeed = entity.speed_move"
        "\tend"))
    (def-pico-function
      (name get_direction_to_turn)
      (params (cur_angle desired_angle))
      (line-range (619 629))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "-.5 < angle_delta and angle_delta <= .5"))
      (decompiled-pseudo-code
        (set! angle_delta "desired_angle-cur_angle")
        (set! turn_result "0")
        (when "-.5 < angle_delta and angle_delta <= .5")
        (set! turn_result "angle_delta")
        (when "angle_delta > .5")
        (set! turn_result "angle_delta - 1")
        (when "angle_delta <= -.5")
        (set! turn_result "angle_delta + 1"))
      (body-lines
        "function get_direction_to_turn(cur_angle, desired_angle)"
        "\tlocal angle_delta = desired_angle-cur_angle"
        ""
        "\tlocal turn_result = 0"
        "\tif -.5 < angle_delta and angle_delta <= .5 then"
        "\t\tturn_result = angle_delta"
        "\telseif angle_delta > .5 then"
        "\t\tturn_result = angle_delta - 1"
        "\telseif angle_delta <= -.5 then"
        "\t\tturn_result = angle_delta + 1"
        "\tend"))
    (def-pico-function
      (name get_rebound_angle_speed)
      (params (angle speed))
      (line-range (638 642))
      (api-calls ())
      (called-functions (randc))
      (structured-ast
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! dir "-.125")
        (when "randc()")
        (set! dir ".125"))
      (body-lines
        "function get_rebound_angle_speed(angle, speed)"
        "\tlocal dir = -.125"
        "\tif randc() then"
        "\t\tdir = .125"
        "\tend"))
    (def-pico-function
      (name get_angle_from_input)
      (params ())
      (line-range (646 649))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "p1.recovery_time_rem > 0")
        (return-expr "0"))
      (decompiled-pseudo-code
        (when "p1.recovery_time_rem > 0")
        (return "0"))
      (body-lines
        "function get_angle_from_input()"
        "\tif p1.recovery_time_rem > 0 then"
        "\t\treturn 0"
        "\tend"))
    (def-pico-function
      (name m_player)
      (params (setx sety))
      (line-range (677 709))
      (api-calls ())
      (called-functions (move))
      (structured-ast
        (seq-block 33))
      (decompiled-pseudo-code
        (set! name "\"\",")
        (set! pcolor "7,")
        (set! scolor "6,")
        (set! is_player "true,")
        (set! x "setx,")
        (set! y "sety,")
        (set! angle "0,")
        (set! speed_move "0,")
        (set! speed_move_max "1.25,")
        (set! col_w "6,")
        (set! col_h "6,")
        (set! col_off "0,")
        (set! curanim "\"move\",")
        (set! curframe "1,")
        (set! animtick "0,")
        (set! flipx "true,")
        (set! head_shift "0,")
        (set! body_shift "0,")
        (set! hp_cur "2,")
        (set! is_dead "false,")
        (set! recovery_time_rem "0,")
        (set! ready_time "150,")
        (set! invuln_frames "0,")
        (set! is_slashing "false,"))
      (body-lines
        "function m_player(setx, sety)"
        ""
        "\tlocal p="
        "\t{"
        "\t\tname = \"\","
        "\t\tpcolor=7,"
        "\t\tscolor=6,"
        "\t\tis_player = true,"
        "\t\tx=setx,"
        "\t\ty=sety,"
        "\t\tangle=0,"
        "\t\tspeed_move=0,"
        "\t\tspeed_move_max=1.25,"
        "\t\tcol_w=6,"
        "\t\tcol_h=6,"
        "\t\tcol_off=0,"
        ""
        "\t\tcuranim=\"move\","
        "\t\tcurframe=1,"
        "\t\tanimtick=0,"
        "\t\tflipx=true,"
        "\t\thead_shift=0,"
        "\t\tbody_shift=0,"
        ""
        "    hp_cur=2,"
        "\t\tis_dead=false,"
        ""
        "    recovery_time_rem = 0,"
        "\t\tready_time = 150,"
        "    invuln_frames = 0,"
        "\t\tis_slashing = false,"
        ""))
    (def-pico-function
      (name init)
      (params (self))
      (line-range (710 711))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 2))
      (decompiled-pseudo-code
        (set! init "function(self)"))
      (body-lines
        "\t\tinit=function(self)"
        "\t\tend,"))
    (def-pico-function
      (name damage)
      (params (self source do_kill))
      (line-range (713 716))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.invuln_frames > 0 and not do_kill")
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! damage "function(self, source, do_kill)")
        (when "self.invuln_frames > 0 and not do_kill")
        (return "false"))
      (body-lines
        "    damage=function(self, source, do_kill)"
        "      if self.invuln_frames > 0 and not do_kill then"
        "        return false"
        "      end"))
    (def-pico-function
      (name slash)
      (params (self))
      (line-range (739 758))
      (api-calls (sfx))
      (called-functions (a_anim_set frnda))
      (structured-ast
        (if-cond "not self.is_slashing"))
      (decompiled-pseudo-code
        (set! slash "function(self)")
        (when "not self.is_slashing")
        (call sfx "frnda(3,4)")
        (call a_anim_set "self, \"windup\""))
      (body-lines
        "\t\tslash=function(self)"
        "\t\t\tif not self.is_slashing then"
        ""
        "\t\t\t\tsfx(frnda(3,4))"
        "\t\t\t\ta_anim_set(self, \"windup\")"
        "\t\t\t\tself.slash_has_impacted,"
        "\t\t\t\tself.is_slashing,"
        "\t\t\t\tself.slash_time,"
        "\t\t\t\tself.slash_speed,"
        "\t\t\t\tself.slash_angle,"
        "\t\t\t\tself.speed_move,"
        "\t\t\t\tself.ready_time ="
        "\t\t\t\tfalse,"
        "\t\t\t\ttrue,"
        "\t\t\t\t5,"
        "\t\t\t\t6,"
        "\t\t\t\tself.angle,"
        "\t\t\t\t0,"
        "\t\t\t\t45"
        "\t\t\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (761 764))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.is_dead")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (when "self.is_dead")
        (return ""))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tif self.is_dead then"
        "\t\t\t\treturn"
        "\t\t\tend"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (851 854))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.is_dead")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (when "self.is_dead")
        (return ""))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tif self.is_dead then"
        "\t\t\t\treturn"
        "\t\t\tend"))
    (def-pico-function
      (name m_emotion)
      (params (entity emotion))
      (line-range (883 891))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 9))
      (decompiled-pseudo-code
        (set! owner "entity,")
        (set! curanim "emotion,")
        (set! curframe "1,")
        (set! animtick "0,")
        (set! color "g_color_interface,"))
      (body-lines
        "function m_emotion(entity, emotion)"
        "\tlocal e ="
        "\t{"
        "\t\towner=entity,"
        "\t\tcuranim=emotion,"
        "\t\tcurframe=1,"
        "\t\tanimtick=0,"
        "\t\tcolor=g_color_interface,"
        ""))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (892 894))
      (api-calls ())
      (called-functions (a_anim_update))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (call a_anim_update "self, emotion_anims"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\ta_anim_update(self, emotion_anims)"
        "\t\tend,"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (896 905))
      (api-calls (pal spr))
      (called-functions ())
      (structured-ast
        (seq-block 10))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (set! |frame, c_o| "emotion_anims[self.curanim].frames[self.curframe], -4")
        (call pal "7, self.color")
        (call pal ""))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tlocal frame, c_o = emotion_anims[self.curanim].frames[self.curframe], -4"
        "\t\t\tpal(7, self.color)"
        ""
        "\t\t\tspr(frame,"
        "\t\t\t\tself.owner.x+c_o,"
        "\t\t\t\tself.owner.y+c_o-10,"
        "\t\t\t\t1,1, false)"
        "\t\t\tpal()"
        "\t\tend,"))
    (def-pico-function
      (name get_flipx_from_angle)
      (params (angle))
      (line-range (912 915))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "angle > .25 and angle <= .75")
        (return-expr "true"))
      (decompiled-pseudo-code
        (when "angle > .25 and angle <= .75")
        (return "true"))
      (body-lines
        "function get_flipx_from_angle(angle)"
        "\tif angle > .25 and angle <= .75 then"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name get_dir_to_player)
      (params (entity))
      (line-range (919 921))
      (api-calls (atan2))
      (called-functions ())
      (structured-ast
        (return-expr "(atan2(entity.x - p1.x, entity.y - p1.y)+.5)%1"))
      (decompiled-pseudo-code
        (return "(atan2(entity.x - p1.x, entity.y - p1.y)+.5)%1"))
      (body-lines
        "function get_dir_to_player(entity)"
        "\treturn (atan2(entity.x - p1.x, entity.y - p1.y)+.5)%1"
        "end"))
    (def-pico-function
      (name get_yboboffset)
      (params (self))
      (line-range (923 928))
      (api-calls ())
      (called-functions (move))
      (structured-ast
        (if-cond "self.curanim == \"move\"")
        (if-cond "self.curframe % 2 == 0")
        (return-expr "-1"))
      (decompiled-pseudo-code
        (when "self.curanim == \"move\"")
        (when "self.curframe % 2 == 0")
        (return "-1"))
      (body-lines
        "function get_yboboffset(self)"
        ""
        "\tif self.curanim == \"move\" then"
        "\t\tif self.curframe % 2 == 0 then"
        "\t\t\treturn -1"
        "\t\tend"))
    (def-pico-function
      (name m_step)
      (params (x y))
      (line-range (933 940))
      (api-calls (add))
      (called-functions (frnda))
      (structured-ast
        (seq-block 8))
      (decompiled-pseudo-code
        (set! x "x-frnda(4,2),")
        (set! y "y,")
        (call add "list_steps, s"))
      (body-lines
        "function m_step(x,y)"
        "\tlocal s ="
        "\t{"
        "\t\tx=x-frnda(4,2),"
        "\t\ty=y,"
        "\t}"
        "\tadd(list_steps, s)"
        "end"))
    (def-pico-function
      (name check_for_footsteps)
      (params (self))
      (line-range (942 947))
      (api-calls ())
      (called-functions (m_step randc))
      (structured-ast
        (if-cond "g_season == 3 and not g_level_indoor")
        (if-cond "randc(50"))
      (decompiled-pseudo-code
        (when "g_season == 3 and not g_level_indoor")
        (when "randc(50)")
        (call m_step "self.x, self.y"))
      (body-lines
        "function check_for_footsteps(self)"
        "\t-- do snow stuff"
        "\tif g_season == 3 and not g_level_indoor then"
        "\t\tif randc(50) then"
        "\t\t\tm_step(self.x, self.y)"
        "\t\tend"))
    (def-pico-function
      (name draw_character)
      (params (self))
      (line-range (951 958))
      (api-calls (pal))
      (called-functions (a_set_invuln_flash get_yboboffset))
      (structured-ast
        (if-cond "not a_set_invuln_flash(self"))
      (decompiled-pseudo-code
        (set! yboboffset "get_yboboffset(self)")
        (when "not a_set_invuln_flash(self)")
        (call pal "6,self.scolor")
        (call pal "7,self.pcolor"))
      (body-lines
        "function draw_character(self)"
        ""
        "\tlocal yboboffset = get_yboboffset(self)"
        ""
        "\tif not a_set_invuln_flash(self) then"
        "\t\tpal(6,self.scolor)"
        "\t\tpal(7,self.pcolor)"
        "\tend"))
    (def-pico-function
      (name split_entity)
      (params (entity angle))
      (line-range (978 981))
      (api-calls (abs rnd))
      (called-functions (m_bodypart))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (call m_bodypart "entity, 42, entity.pcolor, (angle+.300+rnd(.325))%1")
        (call m_bodypart "entity, 56+entity.head_shift, entity.scolor, abs(angle-.300-rnd(.325))%1"))
      (body-lines
        "function split_entity(entity, angle)"
        "\tm_bodypart(entity, 42, entity.pcolor, (angle+.300+rnd(.325))%1)"
        "\tm_bodypart(entity, 56+entity.head_shift, entity.scolor, abs(angle-.300-rnd(.325))%1)"
        "end"))
    (def-pico-function
      (name rndbool)
      (params ())
      (line-range (983 985))
      (api-calls ())
      (called-functions (frnd))
      (structured-ast
        (return-expr "frnd(2) == 0"))
      (decompiled-pseudo-code
        (return "frnd(2) == 0"))
      (body-lines
        "function rndbool()"
        "\treturn frnd(2) == 0"
        "end"))
    (def-pico-function
      (name m_bodypart)
      (params (entity sprite replace_color angle))
      (line-range (987 1000))
      (api-calls (rnd))
      (called-functions (frnda rndbool))
      (structured-ast
        (seq-block 14))
      (decompiled-pseudo-code
        (set! x "entity.x,")
        (set! y "entity.y,")
        (set! replace_color "replace_color,")
        (set! angle "angle,")
        (set! sprite "sprite,")
        (set! speed_move ".5+rnd(.5),")
        (set! flip_x "rndbool(),")
        (set! decay_time "frnda(25,25),"))
      (body-lines
        "function m_bodypart(entity, sprite, replace_color, angle)"
        "\tlocal h="
        "\t{"
        "\t\tx=entity.x,"
        "\t\ty=entity.y,"
        "\t\treplace_color = replace_color,"
        "\t\tangle=angle,"
        "\t\tsprite=sprite,"
        "\t\tspeed_move=.5+rnd(.5),"
        ""
        "\t\tflip_x=rndbool(),"
        ""
        "\t\tdecay_time=frnda(25,25),"
        ""))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1001 1011))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "self.speed_move < .1")
        (if-cond "self.decay_time < 0")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (when "self.speed_move < .1")
        (-= self.decay_time "1")
        (when "self.decay_time < 0")
        (call del "list_heads, self")
        (call del "list_drawstuff, self")
        (return ""))
      (body-lines
        "\t\tupdate=function(self)"
        ""
        ""
        "\t\t\t-- if we roll to a stop, start counting down cleanup"
        "\t\t\tif self.speed_move < .1 then"
        "\t\t\t\tself.decay_time -= 1"
        "\t\t\t\tif self.decay_time < 0 then"
        "\t\t\t\t\tdel(list_heads, self)"
        "\t\t\t\t\tdel(list_drawstuff, self)"
        "\t\t\t\t\treturn"
        "\t\t\t\tend"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (1031 1044))
      (api-calls (pal spr))
      (called-functions (set_outline))
      (structured-ast
        (seq-block 14))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (set! c_o "-4")
        (call set_outline "")
        (call pal "6, self.replace_color")
        (call pal ""))
      (body-lines
        "\t\tdraw=function(self)"
        ""
        "\t\t\tlocal c_o = -4"
        ""
        "\t\t\tset_outline()"
        "\t\t\tpal(6, self.replace_color)"
        ""
        "\t\t\tspr(self.sprite,"
        "\t\t\t\tself.x+c_o,"
        "\t\t\t\tself.y+1+c_o,"
        "\t\t\t\t1,1,"
        "\t\t\t\tself.flip_x)"
        "\t\t\tpal()"
        "\t\tend,"))
    (def-pico-function
      (name m_object)
      (params (x y spritelist is_deadly))
      (line-range (1051 1062))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 12))
      (decompiled-pseudo-code
        (set! x "x,")
        (set! y "y,")
        (set! col_w "4,")
        (set! col_h "2,")
        (set! spritelist "spritelist,")
        (set! sprite "1,")
        (set! is_static "true,")
        (set! is_deadly "is_deadly,"))
      (body-lines
        "function m_object(x, y, spritelist, is_deadly)"
        "\tlocal o ="
        "\t{"
        "\t\tx=x,"
        "\t\ty=y,"
        "\t\tcol_w=4,"
        "\t\tcol_h=2,"
        "\t\tspritelist=spritelist,"
        "\t\tsprite=1,"
        "\t\tis_static=true,"
        "\t\tis_deadly=is_deadly,"
        ""))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1063 1064))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 2))
      (decompiled-pseudo-code
        (set! update "function(self)"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\tend,"))
    (def-pico-function
      (name dealt_damage)
      (params (self))
      (line-range (1066 1068))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! dealt_damage "function(self)")
        (set! self.sprite "2"))
      (body-lines
        "\t\tdealt_damage=function(self)"
        "\t\t\tself.sprite = 2"
        "\t\tend,"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (1070 1076))
      (api-calls (pal spr))
      (called-functions (set_outline))
      (structured-ast
        (seq-block 7))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (call set_outline "")
        (call pal "14, 8")
        (call pal "1, g_color_detail")
        (call spr "self.spritelist[self.sprite], x-4, y-4")
        (call pal ""))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tset_outline()"
        "\t\t\tpal(14, 8)"
        "\t\t\tpal(1, g_color_detail)"
        "\t\t\tspr(self.spritelist[self.sprite], x-4, y-4)"
        "\t\t\tpal()"
        "\t\tend,"))
    (def-pico-function
      (name m_food)
      (params (setx sety))
      (line-range (1083 1093))
      (api-calls (del))
      (called-functions (m_object m_part_sprite score_add))
      (structured-ast
        (seq-block 11))
      (decompiled-pseudo-code
        (set! o "m_object(setx, sety, {99, 99}, false)")
        (set! p1.hp_cur "2")
        (call m_part_sprite "106, self.x, self.y, -.1, g_color_outline, g_color_outline, 15, false, true")
        (call score_add "self, 5")
        (call del "list_objects, self")
        (call del "list_drawstuff, self"))
      (body-lines
        "function m_food(setx, sety)"
        "\tlocal o = m_object(setx, sety, {99, 99}, false)"
        "\to.col_h, o.col_w, o.eat ="
        "\t6, 6,"
        "\tfunction(self)"
        "\t\tp1.hp_cur = 2"
        "\t\tm_part_sprite(106, self.x, self.y, -.1, g_color_outline, g_color_outline, 15, false, true)"
        "\t\tscore_add(self, 5)"
        "\t\tdel(list_objects, self)"
        "\t\tdel(list_drawstuff, self)"
        "\tend"))
    (def-pico-function
      (name add_to_people)
      (params (entity))
      (line-range (1096 1102))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (if-cond "entity.is_villager"))
      (decompiled-pseudo-code
        (when "entity.is_villager")
        (call add "list_villagers, entity")
        (call add "list_enemies, entity"))
      (body-lines
        "function add_to_people(entity)"
        ""
        "\tif entity.is_villager then"
        "\t\tadd(list_villagers, entity)"
        "\telse"
        "\t\tadd(list_enemies, entity)"
        "\tend"))
    (def-pico-function
      (name del_from_people)
      (params (entity))
      (line-range (1108 1113))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "entity.is_villager"))
      (decompiled-pseudo-code
        (when "entity.is_villager")
        (call del "list_villagers, entity")
        (when "not entity.is_furniture")
        (call del "list_enemies, entity"))
      (body-lines
        "function del_from_people(entity)"
        "\tif entity.is_villager then"
        "\t\tdel(list_villagers, entity)"
        "\telseif not entity.is_furniture then"
        "\t\tdel(list_enemies, entity)"
        "\tend"))
    (def-pico-function
      (name a_alert_checkforwindup)
      (params (entity))
      (line-range (1121 1131))
      (api-calls ())
      (called-functions (a_anim_set get_dir_to_player get_flipx_from_angle is_level_active is_near_objs))
      (structured-ast
        (if-cond "is_level_active(")
        (return-expr "true")
        (return-expr "false"))
      (decompiled-pseudo-code
        (when "is_level_active() and entity.windup_time_rem == 0 and is_near_objs(entity, p1, entity.alert_distance)")
        (set! entity.flipx "get_flipx_from_angle(entity.desired_angle)")
        (call a_anim_set "entity, \"windup\"")
        (return "true")
        (return "false"))
      (body-lines
        "function a_alert_checkforwindup(entity)"
        "\tif is_level_active() and entity.windup_time_rem == 0 and is_near_objs(entity, p1, entity.alert_distance) then"
        "\t\tentity.windup_time_rem, entity.desired_angle ="
        "\t\tentity.windup_time-entity.emotion_count*3, get_dir_to_player(entity)"
        ""
        "\t\tentity.flipx = get_flipx_from_angle(entity.desired_angle)"
        "\t\ta_anim_set(entity, \"windup\")"
        "\t\treturn true"
        "\telse"
        "\t\treturn false"
        "\tend"))
    (def-pico-function
      (name a_deviate)
      (params (entity time))
      (line-range (1134 1137))
      (api-calls ())
      (called-functions (frnda randc))
      (structured-ast
        (if-cond "randc(10"))
      (decompiled-pseudo-code
        (when "randc(10)")
        (set! entity.deviation_time "frnda(time, time)"))
      (body-lines
        "function a_deviate(entity, time)"
        "\tif randc(10) then"
        "\t\tentity.deviation_time = frnda(time, time)"
        "\tend"))
    (def-pico-function
      (name a_random_turn)
      (params (entity))
      (line-range (1140 1144))
      (api-calls ())
      (called-functions (randc))
      (structured-ast
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! angle_adjust ".25")
        (when "randc()")
        (set! angle_adjust "0-angle_adjust"))
      (body-lines
        "function a_random_turn(entity)"
        "\tlocal angle_adjust = .25"
        "\tif randc() then"
        "\t\tangle_adjust = 0-angle_adjust"
        "\tend"))
    (def-pico-function
      (name m_enemy_villager)
      (params (setx sety))
      (line-range (1149 1153))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety, true)"))
      (body-lines
        "function m_enemy_villager(setx, sety)"
        "\tlocal e = m_enemy(setx, sety, true)"
        "  e.head_shift, e.body_shift, e.pcolor, e.scolor, e.score ="
        "\t6, 16, 11, 4, -10"
        ""))
    (def-pico-function
      (name kill_class)
      (params (self source))
      (line-range (1154 1159))
      (api-calls ())
      (called-functions (level_end_villager_died))
      (structured-ast
        (if-cond "source == p1"))
      (decompiled-pseudo-code
        (set! e.kill_class "function(self, source)")
        (when "source == p1")
        (call level_end_villager_died "true")
        (call level_end_villager_died "false"))
      (body-lines
        "\te.kill_class=function(self, source)"
        "\t\tif source == p1 then"
        "\t\t\tlevel_end_villager_died(true)"
        "\t\telse"
        "\t\t\tlevel_end_villager_died(false)"
        "\t\tend"))
    (def-pico-function
      (name touch_class)
      (params (self))
      (line-range (1163 1167))
      (api-calls ())
      (called-functions (del_from_people score_add))
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.touch_class "function(self)")
        (call score_add "self, 0-self.score-2.5*self.emotion_count")
        (call del_from_people "self")
        (return "true"))
      (body-lines
        "\te.touch_class=function(self)"
        "\t\tscore_add(self, 0-self.score-2.5*self.emotion_count)"
        "\t\tdel_from_people(self)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1169 1172))
      (api-calls ())
      (called-functions (a_deviate a_random_turn))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! e.move "function(self)")
        (call a_deviate "self, 5")
        (call a_random_turn "self"))
      (body-lines
        "\te.move=function(self)"
        "\t\ta_deviate(self, 5)"
        "\t\ta_random_turn(self)"
        "\tend"))
    (def-pico-function
      (name draw_class)
      (params (self))
      (line-range (1174 1175))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 2))
      (decompiled-pseudo-code
        (set! e.draw_class "function(self)"))
      (body-lines
        "\te.draw_class=function(self)"
        "\tend"))
    (def-pico-function
      (name nearest_angle)
      (params (angle))
      (line-range (1180 1189))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "angle>.825 or angle < .125"))
      (decompiled-pseudo-code
        (when "angle>.825 or angle < .125")
        (set! angle "0")
        (when "angle < .375")
        (set! angle ".25")
        (when "angle < .625")
        (set! angle ".5")
        (set! angle ".75"))
      (body-lines
        "function nearest_angle(angle)"
        "\tif angle>.825 or angle < .125 then"
        "\t\tangle = 0"
        "\telseif angle < .375 then"
        "\t\tangle = .25"
        "\telseif angle < .625 then"
        "\t\tangle = .5"
        "\telse"
        "\t\tangle = .75"
        "\tend"))
    (def-pico-function
      (name m_arrow)
      (params (x y angle))
      (line-range (1193 1206))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 14))
      (decompiled-pseudo-code
        (set! x "x,")
        (set! y "y,")
        (set! col_w "4,")
        (set! col_h "4,")
        (set! angle "angle,")
        (set! speed_move "3,")
        (set! is_static "false,")
        (set! is_deadly "true,")
        (set! sprite "40,")
        (set! flipx "false,"))
      (body-lines
        "function m_arrow(x, y, angle)"
        "\tlocal a ="
        "\t{"
        "\t\tx=x,"
        "\t\ty=y,"
        "\t\tcol_w=4,"
        "\t\tcol_h=4,"
        "\t\tangle=angle,"
        "\t\tspeed_move=3,"
        "\t\tis_static=false,"
        "\t\tis_deadly=true,"
        "\t\tsprite=40,"
        "\t\tflipx=false,"
        ""))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (1207 1211))
      (api-calls (pal spr))
      (called-functions (set_outline))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (call set_outline "")
        (call spr "self.sprite, self.x-4, self.y-4, 1, 1, self.flipx")
        (call pal ""))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tset_outline()"
        "\t\t\tspr(self.sprite, self.x-4, self.y-4, 1, 1, self.flipx)"
        "\t\t\tpal()"
        "\t\tend,"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1213 1217))
      (api-calls ())
      (called-functions (a_move_angle constrain_to_screen dealt_damage))
      (structured-ast
        (if-cond "constrain_to_screen(self"))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (call a_move_angle "self")
        (when "constrain_to_screen(self)")
        (call self:dealt_damage ""))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\ta_move_angle(self)"
        "\t\t\tif constrain_to_screen(self) then"
        "\t\t\t\tself:dealt_damage()"
        "\t\t\tend"))
    (def-pico-function
      (name dealt_damage)
      (params (self))
      (line-range (1220 1223))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! dealt_damage "function(self)")
        (call del "list_objects, self")
        (call del "list_drawstuff, self"))
      (body-lines
        "\t\tdealt_damage=function(self)"
        "\t\t\tdel(list_objects, self)"
        "\t\t\tdel(list_drawstuff, self)"
        "\t\tend,"))
    (def-pico-function
      (name m_enemy_archer)
      (params (setx sety))
      (line-range (1233 1236))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety)")
        (set! |e.head_shift, e.pcolor, e.scolor, e.alert_distance, e.windup_time, e.time_between_attacks, e.attack_time, e.attack_is_shot| "4, 14, 13, 60, 30, 60, 30, true"))
      (body-lines
        "function m_enemy_archer(setx, sety)"
        "\tlocal e = m_enemy(setx, sety)"
        "\te.head_shift, e.pcolor, e.scolor, e.alert_distance, e.windup_time, e.time_between_attacks, e.attack_time, e.attack_is_shot = 4, 14, 13, 60, 30, 60, 30, true"
        ""))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1237 1241))
      (api-calls ())
      (called-functions (a_deviate get_dir_to_player is_level_active))
      (structured-ast
        (if-cond "is_level_active("))
      (decompiled-pseudo-code
        (set! e.move "function(self)")
        (call a_deviate "self, 10")
        (when "is_level_active()")
        (set! self.angle_desired "get_dir_to_player(self)"))
      (body-lines
        "\te.move=function(self)"
        "\t\ta_deviate(self, 10)"
        "\t\tif is_level_active() then"
        "\t\t\tself.angle_desired = get_dir_to_player(self)"
        "\t\tend"))
    (def-pico-function
      (name alert_class)
      (params (self))
      (line-range (1244 1252))
      (api-calls (abs sfx))
      (called-functions (a_alert_checkforwindup nearest_angle))
      (structured-ast
        (if-cond "abs(self.x - p1.x")
        (if-cond "a_alert_checkforwindup(self")
        (return-expr "true")
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! e.alert_class "function(self)")
        (when "abs(self.x - p1.x) < 5 or abs(self.y - p1.y) < 5")
        (when "a_alert_checkforwindup(self)")
        (set! self.desired_angle "nearest_angle(self.desired_angle)")
        (call sfx "24")
        (return "true")
        (return "false"))
      (body-lines
        "\te.alert_class=function(self)"
        "\t\tif abs(self.x - p1.x) < 5 or abs(self.y - p1.y) < 5 then"
        "\t\t\tif a_alert_checkforwindup(self) then"
        "\t\t\t\tself.desired_angle = nearest_angle(self.desired_angle)"
        "\t\t\t\tsfx(24)"
        "\t\t\t\treturn true"
        "\t\t\telse"
        "\t\t\t\treturn false"
        "\t\t\tend"))
    (def-pico-function
      (name fire_arrow)
      (params (self))
      (line-range (1256 1259))
      (api-calls (sfx))
      (called-functions (m_arrow))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! e.fire_arrow "function(self)")
        (call sfx "17")
        (call m_arrow "self.x, self.y, self.desired_angle"))
      (body-lines
        "\te.fire_arrow=function(self)"
        "\t\tsfx(17)"
        "\t\tm_arrow(self.x, self.y, self.desired_angle)"
        "\tend"))
    (def-pico-function
      (name draw_class)
      (params (self))
      (line-range (1261 1269))
      (api-calls ())
      (called-functions (set_outline))
      (structured-ast
        (if-cond "self.windup_time_rem > 0")
        (if-cond "self.desired_angle == .75"))
      (decompiled-pseudo-code
        (set! e.draw_class "function(self)")
        (when "self.windup_time_rem > 0")
        (call set_outline "")
        (set! |arrow_sprite, doflipy| "40, false")
        (when "self.desired_angle == .75")
        (set! |arrow_sprite, doflipy| "41, true")
        (when "self.desired_angle == .25")
        (set! arrow_sprite "41"))
      (body-lines
        "\te.draw_class=function(self)"
        "\t\tif self.windup_time_rem > 0 then"
        "\t\t\tset_outline()"
        "\t\t\tlocal arrow_sprite, doflipy = 40, false"
        "\t\t\tif self.desired_angle == .75 then"
        "\t\t\t\tarrow_sprite, doflipy = 41, true"
        "\t\t\telseif self.desired_angle == .25 then"
        "\t\t\t\tarrow_sprite = 41"
        "\t\t\tend"))
    (def-pico-function
      (name m_enemy_wander)
      (params (setx sety))
      (line-range (1276 1280))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety)")
        (set! |e.head_shift, e.pcolor| "1, 9"))
      (body-lines
        "function m_enemy_wander(setx, sety)"
        "\tlocal e = m_enemy(setx, sety)"
        ""
        "\te.head_shift, e.pcolor = 1, 9"
        ""))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1281 1284))
      (api-calls ())
      (called-functions (a_deviate a_random_turn))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! e.move "function(self)")
        (call a_deviate "self, 15")
        (call a_random_turn "self"))
      (body-lines
        "\te.move=function(self)"
        "\t\ta_deviate(self, 15)"
        "\t\ta_random_turn(self)"
        "\tend"))
    (def-pico-function
      (name alert_class)
      (params (self))
      (line-range (1286 1288))
      (api-calls ())
      (called-functions (a_alert_checkforwindup))
      (structured-ast
        (return-expr "a_alert_checkforwindup(self)"))
      (decompiled-pseudo-code
        (set! e.alert_class "function(self)")
        (return "a_alert_checkforwindup(self)"))
      (body-lines
        "\te.alert_class=function(self)"
        "\t\treturn a_alert_checkforwindup(self)"
        "\tend"))
    (def-pico-function
      (name m_enemy_bomber)
      (params (setx sety))
      (line-range (1293 1298))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 6))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety)"))
      (body-lines
        "function m_enemy_bomber(setx, sety)"
        "\tlocal e = m_enemy(setx, sety)"
        ""
        " \te.pcolor, e.scolor, e.head_shift, e.is_fuse_lit, e.is_bomber ="
        "\t8, 4, 3, false, true"
        ""))
    (def-pico-function
      (name touch_class)
      (params (self))
      (line-range (1299 1302))
      (api-calls ())
      (called-functions (explode))
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.touch_class "function(self)")
        (call self:explode "nil, true")
        (return "true"))
      (body-lines
        "\te.touch_class=function(self)"
        "\t\tself:explode(nil, true)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name update_class)
      (params (self))
      (line-range (1304 1308))
      (api-calls (sfx))
      (called-functions (is_near_objs))
      (structured-ast
        (if-cond "not self.is_fuse_lit and is_near_objs(self, p1, 25"))
      (decompiled-pseudo-code
        (set! e.update_class "function(self)")
        (when "not self.is_fuse_lit and is_near_objs(self, p1, 25)")
        (set! |self.is_fuse_lit, self.fuse_timer, self.emotion_count, self.speed_move| "true, 500, 1, self.speed_move_orig*2")
        (call sfx "35"))
      (body-lines
        "\te.update_class=function(self)"
        "\t\tif not self.is_fuse_lit and is_near_objs(self, p1, 25) then"
        "\t\t\tself.is_fuse_lit, self.fuse_timer, self.emotion_count, self.speed_move = true, 500, 1, self.speed_move_orig*2"
        "\t\t\tsfx(35)"
        "\t\tend"))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1321 1326))
      (api-calls ())
      (called-functions (a_deviate get_dir_to_player is_level_active))
      (structured-ast
        (if-cond "is_level_active("))
      (decompiled-pseudo-code
        (set! e.move "function(self)")
        (call a_deviate "self, 10")
        (when "is_level_active()")
        (set! self.angle_desired "get_dir_to_player(self)"))
      (body-lines
        "\te.move=function(self)"
        ""
        "\t\ta_deviate(self, 10)"
        "\t\tif is_level_active() then"
        "\t\t\tself.angle_desired = get_dir_to_player(self)"
        "\t\tend"))
    (def-pico-function
      (name explode)
      (params (self source no_score))
      (line-range (1329 1332))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "source != nil and source != p1 and not source.is_heavy"))
      (decompiled-pseudo-code
        (set! e.explode "function(self, source, no_score)")
        (when "source != nil and source != p1 and not source.is_heavy")
        (set! self.score_multiplier "source.score_multiplier + 1"))
      (body-lines
        "\te.explode=function(self, source, no_score)"
        "\t\tif source != nil and source != p1 and not source.is_heavy then"
        "\t\t\tself.score_multiplier = source.score_multiplier + 1"
        "\t\tend"))
    (def-pico-function
      (name handle_impact_class)
      (params (self source))
      (line-range (1392 1395))
      (api-calls ())
      (called-functions (explode))
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.handle_impact_class "function(self, source)")
        (call self:explode "source")
        (return "true"))
      (body-lines
        "\te.handle_impact_class=function(self, source)"
        "\t\tself:explode(source)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name kill_class)
      (params (self source no_score))
      (line-range (1397 1400))
      (api-calls ())
      (called-functions (explode))
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.kill_class "function(self, source, no_score)")
        (call self:explode "source, no_score")
        (return "true"))
      (body-lines
        "\te.kill_class=function(self, source, no_score)"
        "\t\tself:explode(source, no_score)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name draw_class)
      (params (self))
      (line-range (1402 1406))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.flipx"))
      (decompiled-pseudo-code
        (set! e.draw_class "function(self)")
        (set! x_off "-5")
        (when "self.flipx")
        (set! x_off "-3"))
      (body-lines
        "\te.draw_class=function(self)"
        "\t\tlocal x_off = -5"
        "\t\tif self.flipx then"
        "\t\t\tx_off = -3"
        "\t\tend"))
    (def-pico-function
      (name m_enemy_boss)
      (params (setx sety))
      (line-range (1415 1419))
      (api-calls ())
      (called-functions (init m_enemy_seeker))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! e "m_enemy_seeker(setx, sety)")
        (set! |e.is_armored, e.head_shift, e.pcolor, e.scolor, e.speed_move_orig| "true, 5, 13, 6, .5")
        (call e:init ""))
      (body-lines
        "function m_enemy_boss(setx, sety)"
        "\tlocal e = m_enemy_seeker(setx, sety)"
        "\te.is_armored, e.head_shift, e.pcolor, e.scolor, e.speed_move_orig = true, 5, 13, 6, .5"
        "\te:init()"
        "end"))
    (def-pico-function
      (name m_enemy_seeker)
      (params (setx sety))
      (line-range (1421 1425))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety)")
        (set! e.head_shift "2"))
      (body-lines
        "function m_enemy_seeker(setx, sety)"
        ""
        "\tlocal e = m_enemy(setx, sety)"
        ""
        "\te.head_shift = 2"))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1426 1431))
      (api-calls ())
      (called-functions (a_deviate get_dir_to_player is_level_active))
      (structured-ast
        (if-cond "is_level_active("))
      (decompiled-pseudo-code
        (set! e.move "function(self)")
        (call a_deviate "self, 10")
        (when "is_level_active()")
        (set! self.angle_desired "get_dir_to_player(self)"))
      (body-lines
        "\te.move=function(self)"
        "\t\ta_deviate(self, 10)"
        ""
        "\t\tif is_level_active() then"
        "\t\t\tself.angle_desired = get_dir_to_player(self)"
        "\t\tend"))
    (def-pico-function
      (name alert_class)
      (params (self))
      (line-range (1434 1436))
      (api-calls ())
      (called-functions (a_alert_checkforwindup))
      (structured-ast
        (return-expr "a_alert_checkforwindup(self)"))
      (decompiled-pseudo-code
        (set! e.alert_class "function(self)")
        (return "a_alert_checkforwindup(self)"))
      (body-lines
        "\te.alert_class=function(self)"
        "\t\treturn a_alert_checkforwindup(self)"
        "\tend"))
    (def-pico-function
      (name m_enemy_furniture)
      (params (setx sety sprite is_heavy))
      (line-range (1441 1443))
      (api-calls ())
      (called-functions (m_enemy))
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! e "m_enemy(setx, sety)"))
      (body-lines
        "function m_enemy_furniture(setx, sety, sprite, is_heavy)"
        "\tlocal e = m_enemy(setx, sety)"
        ""))
    (def-pico-function
      (name update_class)
      (params (self))
      (line-range (1444 1448))
      (api-calls ())
      (called-functions (a_fly check_for_footsteps))
      (structured-ast
        (if-cond "self.is_flying"))
      (decompiled-pseudo-code
        (set! e.update_class "function(self)")
        (when "self.is_flying")
        (call check_for_footsteps "self")
        (call a_fly "self"))
      (body-lines
        "\te.update_class=function(self)"
        "\t\tif self.is_flying then"
        "\t\t\tcheck_for_footsteps(self)"
        "\t\t\ta_fly(self)"
        "\t\t  end"))
    (def-pico-function
      (name kill_class)
      (params (self))
      (line-range (1452 1455))
      (api-calls ())
      (called-functions (del_from_people))
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.kill_class "function(self)")
        (call del_from_people "self")
        (return "true"))
      (body-lines
        "\te.kill_class=function(self)"
        "\t  del_from_people(self)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name touch_class)
      (params (self))
      (line-range (1457 1459))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! e.touch_class "function(self)")
        (return "true"))
      (body-lines
        "\te.touch_class=function(self)"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name m_enemy)
      (params (setx sety is_villager))
      (line-range (1467 1522))
      (api-calls (rnd))
      (called-functions (frnd move))
      (structured-ast
        (seq-block 56))
      (decompiled-pseudo-code
        (set! x "setx,")
        (set! y "sety,")
        (set! pcolor "10,")
        (set! scolor "7,")
        (set! is_villager "is_villager or false,")
        (set! angle "0,")
        (set! angle_desired "0,")
        (set! alert_distance "15,")
        (set! speed_turn ".01,")
        (set! speed_move_orig ".25+rnd(.1),")
        (set! speed_move "0,")
        (set! windup_time "25,")
        (set! windup_time_rem "0,")
        (set! deviation_time "0,")
        (set! col_w "6,")
        (set! col_h "6,")
        (set! col_off "0,")
        (set! curanim "\"move\",")
        (set! curframe "1,")
        (set! animtick "0,")
        (set! flipx "true,")
        (set! head_shift "0,")
        (set! body_shift "0,")
        (set! emotion "nil,"))
      (body-lines
        "function m_enemy(setx, sety, is_villager)"
        "\tlocal e="
        "\t{"
        "\t\tx=setx,"
        "\t\ty=sety,"
        "\t\tpcolor=10,"
        "\t\tscolor=7,"
        "\t\tis_villager = is_villager or false,"
        ""
        "\t\tangle=0,"
        "\t\tangle_desired=0,"
        "\t\talert_distance=15,"
        "\t\tspeed_turn=.01,"
        "\t\tspeed_move_orig=.25+rnd(.1),"
        "\t\tspeed_move=0,"
        ""
        "\t\twindup_time=25,"
        "\t\twindup_time_rem=0,"
        "\t\tdeviation_time=0,"
        ""
        "\t\tcol_w=6,"
        "\t\tcol_h=6,"
        "\t\tcol_off=0,"
        ""
        "\t\tcuranim=\"move\","
        "\t\tcurframe=1,"
        "\t\tanimtick=0,"
        "\t\tflipx=true,"
        ""
        "\t\thead_shift=0,"
        "\t\tbody_shift=0,"
        ""))
    (def-pico-function
      (name init)
      (params (self))
      (line-range (1523 1527))
      (api-calls (atan2))
      (called-functions (constrain_to_screen is_level_active))
      (structured-ast
        (if-cond "is_level_active("))
      (decompiled-pseudo-code
        (set! init "function(self)")
        (when "is_level_active()")
        (set! |self.invuln_frames, self.speed_move, self.angle| "30, self.speed_move_orig, (atan2(self.x - p1.x, self.y - p1.y)+.5)%1")
        (call constrain_to_screen "self"))
      (body-lines
        "\t\tinit=function(self)"
        "\t\t\tif is_level_active() then"
        "\t\t\t\tself.invuln_frames, self.speed_move, self.angle = 30, self.speed_move_orig, (atan2(self.x - p1.x, self.y - p1.y)+.5)%1"
        "\t\t\t\tconstrain_to_screen(self)"
        "\t\t\tend"))
    (def-pico-function
      (name move)
      (params (self))
      (line-range (1530 1531))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 2))
      (decompiled-pseudo-code
        (set! move "function(self)"))
      (body-lines
        "\t\tmove=function(self)"
        "\t\tend,"))
    (def-pico-function
      (name attack_target)
      (params (self))
      (line-range (1533 1538))
      (api-calls ())
      (called-functions (attack_reset fire_arrow))
      (structured-ast
        (if-cond "self.attack_is_shot")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! attack_target "function(self)")
        (when "self.attack_is_shot")
        (call self:fire_arrow "")
        (call attack_reset "self")
        (return ""))
      (body-lines
        "\t\tattack_target=function(self)"
        "\t\t\tif self.attack_is_shot then"
        "\t\t\t\tself:fire_arrow()"
        "\t\t\t\tattack_reset(self)"
        "\t\t\t\treturn"
        "\t\t\tend"))
    (def-pico-function
      (name handle_impact_class)
      (params (self))
      (line-range (1545 1547))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! handle_impact_class "function(self)")
        (return "false"))
      (body-lines
        "\t\thandle_impact_class=function(self)"
        "\t\t\treturn false"
        "\t\tend,"))
    (def-pico-function
      (name handle_impact)
      (params (self source))
      (line-range (1549 1555))
      (api-calls ())
      (called-functions (a_anim_set emotion_add handle_impact_class m_part_impact))
      (structured-ast
        (if-cond "not self:handle_impact_class(source"))
      (decompiled-pseudo-code
        (set! handle_impact "function(self, source)")
        (when "not self:handle_impact_class(source)")
        (set! |self.is_flying, self.is_flying_impactable, self.windup_time_rem, self.attack_time_rem| "true, true, 0, 0")
        (call a_anim_set "self, \"fly\"")
        (call self:emotion_add "")
        (call m_part_impact "self"))
      (body-lines
        "\t\thandle_impact=function(self, source)"
        "\t\t\tif not self:handle_impact_class(source) then"
        "\t\t\t\tself.is_flying, self.is_flying_impactable, self.windup_time_rem, self.attack_time_rem = true, true, 0, 0"
        "\t\t\t\ta_anim_set(self, \"fly\")"
        "\t\t\t\tself:emotion_add()"
        "\t\t\t\tm_part_impact(self)"
        "\t\t\tend"))
    (def-pico-function
      (name kill_class)
      (params (self))
      (line-range (1558 1560))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! kill_class "function(self)")
        (return "false"))
      (body-lines
        "\t\tkill_class=function(self)"
        "\t\t\treturn false"
        "\t\tend,"))
    (def-pico-function
      (name kill)
      (params (self source no_score angle override))
      (line-range (1562 1566))
      (api-calls ())
      (called-functions (kill_class))
      (structured-ast
        (if-cond "not override")
        (if-cond "self:kill_class(source, no_score")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! kill "function(self, source, no_score, angle, override)")
        (when "not override")
        (when "self:kill_class(source, no_score)")
        (return ""))
      (body-lines
        "\t\tkill=function(self, source, no_score, angle, override)"
        "\t\t\tif not override then"
        "\t\t\t\tif self:kill_class(source, no_score) then"
        "\t\t\t\t\treturn"
        "\t\t\t\tend"))
    (def-pico-function
      (name alert_class)
      (params (self))
      (line-range (1581 1583))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! alert_class "function(self)")
        (return "false"))
      (body-lines
        "\t\talert_class=function(self)"
        "\t\t\treturn false"
        "\t\tend,"))
    (def-pico-function
      (name touch_class)
      (params (self))
      (line-range (1585 1587))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "false"))
      (decompiled-pseudo-code
        (set! touch_class "function(self)")
        (return "false"))
      (body-lines
        "\t\ttouch_class=function(self)"
        "\t\t\treturn false"
        "\t\tend,"))
    (def-pico-function
      (name update_class)
      (params (self))
      (line-range (1589 1591))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "true"))
      (decompiled-pseudo-code
        (set! update_class "function(self)")
        (return "true"))
      (body-lines
        "\t\tupdate_class=function(self)"
        "\t\t\treturn true"
        "\t\tend,"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1593 1598))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "self.invuln_frames > 0"))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (when "self.invuln_frames > 0")
        (-= self.invuln_frames "1")
        (set! self.just_spawned "false"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tif self.invuln_frames > 0 then"
        "\t\t\t\tself.invuln_frames -= 1"
        "\t\t\telse"
        "\t\t\t\tself.just_spawned = false"
        "\t\t\tend"))
    (def-pico-function
      (name draw_class)
      (params (self))
      (line-range (1654 1655))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 2))
      (decompiled-pseudo-code
        (set! draw_class "function(self)"))
      (body-lines
        "\t\tdraw_class=function(self)"
        "\t\tend,"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (1657 1663))
      (api-calls ())
      (called-functions (draw_character draw_class))
      (structured-ast
        (if-cond "not self.is_furniture")
        (if-cond "self.emotion and not self.is_flying"))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (when "not self.is_furniture")
        (call draw_character "self")
        (call self:draw_class "")
        (when "self.emotion and not self.is_flying")
        (call self.emotion:draw ""))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\tif not self.is_furniture then"
        "\t\t\t\tdraw_character(self)"
        "\t\t\t\tself:draw_class()"
        "\t\t\t\tif self.emotion and not self.is_flying then"
        "\t\t\t\t\tself.emotion:draw()"
        "\t\t\t\tend"))
    (def-pico-function
      (name emotion_update)
      (params (self))
      (line-range (1671 1674))
      (api-calls ())
      (called-functions (update))
      (structured-ast
        (if-cond "self.emotion"))
      (decompiled-pseudo-code
        (set! emotion_update "function(self)")
        (when "self.emotion")
        (call self.emotion:update ""))
      (body-lines
        "\t\temotion_update=function(self)"
        "\t\t\tif self.emotion then"
        "\t\t\t\tself.emotion:update()"
        "\t\t\tend"))
    (def-pico-function
      (name emotion_set_from_count)
      (params (self))
      (line-range (1687 1694))
      (api-calls ())
      (called-functions (m_emotion))
      (structured-ast
        (if-cond "self.emotion_count == 3"))
      (decompiled-pseudo-code
        (set! emotion_set_from_count "function(self)")
        (when "self.emotion_count == 3")
        (call m_emotion "self, \"angry\"")
        (when "self.emotion_count >= 1")
        (call m_emotion "self, \"upset\"")
        (set! self.emotion "nil"))
      (body-lines
        "\t\temotion_set_from_count=function(self)"
        "\t\t\tif self.emotion_count == 3 then"
        "\t\t\t\tm_emotion(self, \"angry\")"
        "\t\t\telseif self.emotion_count >= 1 then"
        "\t\t\t\tm_emotion(self, \"upset\")"
        "\t\t\telse"
        "\t\t\t\tself.emotion = nil"
        "\t\t\tend"))
    (def-pico-function
      (name emotion_add)
      (params (self))
      (line-range (1699 1702))
      (api-calls (min))
      (called-functions (emotion_set_from_count))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! emotion_add "function(self)")
        (set! |self.emotion_count, self.emotion_timer| "min(3, self.emotion_count+1), 360")
        (call self:emotion_set_from_count ""))
      (body-lines
        "\t\temotion_add=function(self)"
        "\t\t\tself.emotion_count, self.emotion_timer = min(3, self.emotion_count+1), 360"
        "\t\t\tself:emotion_set_from_count()"
        "\t\tend,"))
    (def-pico-function
      (name get_gen_coords)
      (params ())
      (line-range (1711 1721))
      (api-calls ())
      (called-functions (frnd))
      (structured-ast
        (if-cond "whichside == 0"))
      (decompiled-pseudo-code
        (set! |gen_x, gen_y, whichside| "frnd(128), frnd(128), frnd(4)")
        (when "whichside == 0")
        (set! gen_x "4")
        (when "whichside == 1")
        (set! gen_x "124")
        (when "whichside == 2")
        (set! gen_y "4")
        (set! gen_y "124"))
      (body-lines
        "function get_gen_coords()"
        "\tlocal gen_x, gen_y, whichside = frnd(128), frnd(128), frnd(4)"
        "\tif whichside == 0 then"
        "\t\tgen_x = 4"
        "\telseif whichside == 1 then"
        "\t\tgen_x = 124"
        "\telseif whichside == 2 then"
        "\t\tgen_y = 4"
        "\telse"
        "\t\tgen_y = 124"
        "\tend"))
    (def-pico-function
      (name m_enemy_random)
      (params ())
      (line-range (1725 1735))
      (api-calls ())
      (called-functions (frnda get_gen_coords m_enemy_boss))
      (structured-ast
        (if-cond "enemy_type == 5")
        (if-cond "not g_spawned_boss")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! enemy_type "g_enemy_weights[frnda(#g_enemy_weights)]")
        (when "enemy_type == 5")
        (when "not g_spawned_boss")
        (call m_enemy_boss "get_gen_coords()")
        (set! g_spawned_boss "true")
        (return ""))
      (body-lines
        "function m_enemy_random()"
        ""
        "\tlocal enemy_type = g_enemy_weights[frnda(#g_enemy_weights)]"
        ""
        "\tif enemy_type == 5 then"
        "\t\tif not g_spawned_boss then"
        "\t\t\tm_enemy_boss(get_gen_coords())"
        "\t\t\tg_spawned_boss = true"
        "\t\telse"
        "\t\t\treturn"
        "\t\tend"))
    (def-pico-function
      (name set_cam_pos)
      (params (pos))
      (line-range (1748 1751))
      (api-calls (min))
      (called-functions ())
      (structured-ast
        (if-cond "pos+8<64"))
      (decompiled-pseudo-code
        (when "pos+8<64")
        (+= pos "min(64-(pos+8),4)"))
      (body-lines
        "function set_cam_pos(pos)"
        "\tif pos+8<64 then"
        "\t\tpos+=min(64-(pos+8),4)"
        "\tend"))
    (def-pico-function
      (name m_cam)
      (params ())
      (line-range (1758 1767))
      (api-calls (camera))
      (called-functions ())
      (structured-ast
        (seq-block 10))
      (decompiled-pseudo-code
        (call camera "")
        (set! pos_x "64,")
        (set! pos_y "64,")
        (set! shake_remaining "0,")
        (set! shake_force "0,"))
      (body-lines
        "function m_cam()"
        "\tcamera()"
        "\tlocal c="
        "\t{"
        "\t\tpos_x = 64,"
        "\t\tpos_y = 64,"
        ""
        "\t\tshake_remaining=0,"
        "\t\tshake_force=0,"
        ""))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1768 1771))
      (api-calls (camera max mid))
      (called-functions (cam_pos set_cam_pos))
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! update "function(self)")
        (set! |self.shake_remaining, self.pos_y, self.pos_x| "max(0,self.shake_remaining-1), mid(64, set_cam_pos(self.pos_y), 960), mid(64, set_cam_pos(self.pos_x), 960)")
        (call camera "self:cam_pos()"))
      (body-lines
        "\t\tupdate=function(self)"
        "\t\t\tself.shake_remaining, self.pos_y, self.pos_x = max(0,self.shake_remaining-1), mid(64, set_cam_pos(self.pos_y), 960), mid(64, set_cam_pos(self.pos_x), 960)"
        "\t\t\tcamera(self:cam_pos())"
        "\t\tend,"))
    (def-pico-function
      (name cam_pos)
      (params (self))
      (line-range (1773 1778))
      (api-calls (rnd))
      (called-functions ())
      (structured-ast
        (if-cond "self.shake_remaining>0"))
      (decompiled-pseudo-code
        (set! cam_pos "function(self)")
        (set! |shk_x, shk_y, force| "0, 0, self.shake_force")
        (when "self.shake_remaining>0")
        (set! |shk_x, shk_y| "rnd(force)-force/2, rnd(force)-force/2"))
      (body-lines
        "\t\tcam_pos=function(self)"
        "\t\t\tlocal shk_x, shk_y, force = 0, 0, self.shake_force"
        ""
        "\t\t\tif self.shake_remaining>0 then"
        "\t\t\t\tshk_x, shk_y = rnd(force)-force/2, rnd(force)-force/2"
        "\t\t\tend"))
    (def-pico-function
      (name shake)
      (params (self force duration))
      (line-range (1782 1784))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 3))
      (decompiled-pseudo-code
        (set! shake "function(self, force, duration)")
        (set! |self.shake_force, self.shake_remaining| "force, duration"))
      (body-lines
        "\t\tshake=function(self, force, duration)"
        "\t\t\tself.shake_force, self.shake_remaining = force, duration"
        "\t\tend"))
    (def-pico-function
      (name save_score)
      (params ())
      (line-range (1790 1793))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "g_score_total >= g_high_scores[g_difficulty][1]"))
      (decompiled-pseudo-code
        (when "g_score_total >= g_high_scores[g_difficulty][1]")
        (set! |g_high_scores[g_difficulty][1], g_high_scores[g_difficulty][2]| "g_score_total, g_year"))
      (body-lines
        "function save_score()"
        "\tif g_score_total >= g_high_scores[g_difficulty][1] then"
        "\t\tg_high_scores[g_difficulty][1], g_high_scores[g_difficulty][2] = g_score_total, g_year"
        "\tend"))
    (def-pico-function
      (name level_end)
      (params ())
      (line-range (1803 1806))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 4))
      (decompiled-pseudo-code
        (set! |p1.ready_time, g_game_state, g_transition_time| "300, 6, 150")
        (+= g_score_total "g_score_level"))
      (body-lines
        "function level_end()"
        "\tp1.ready_time, g_game_state, g_transition_time = 300, 6, 150"
        "\tg_score_total += g_score_level"
        "end"))
    (def-pico-function
      (name level_end_win)
      (params ())
      (line-range (1808 1811))
      (api-calls ())
      (called-functions (score_add))
      (structured-ast
        (if-cond "p1.hp_cur > 1"))
      (decompiled-pseudo-code
        (when "p1.hp_cur > 1")
        (call score_add "p1, 25"))
      (body-lines
        "function level_end_win()"
        "\tif p1.hp_cur > 1 then"
        "\t\tscore_add(p1, 25)"
        "\tend"))
    (def-pico-function
      (name level_end_bad)
      (params ())
      (line-range (1817 1822))
      (api-calls (sfx))
      (called-functions (level_end save_score))
      (structured-ast
        (seq-block 6))
      (decompiled-pseudo-code
        (set! g_game_transition_to_state "8")
        (call sfx "12")
        (call level_end "")
        (call save_score ""))
      (body-lines
        "function level_end_bad()"
        "\tg_game_transition_to_state = 8"
        "\tsfx(12)"
        "\tlevel_end()"
        "\tsave_score()"
        "end"))
    (def-pico-function
      (name level_end_villager_died)
      (params (killed_by_player))
      (line-range (1824 1827))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "g_difficulty < 7")
        (return-expr ""))
      (decompiled-pseudo-code
        (when "g_difficulty < 7")
        (return ""))
      (body-lines
        "function level_end_villager_died(killed_by_player)"
        "\tif g_difficulty < 7 then"
        "\t\treturn"
        "\tend"))
    (def-pico-function
      (name level_end_player_died)
      (params (killed_by_obstacle))
      (line-range (1835 1839))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "killed_by_obstacle"))
      (decompiled-pseudo-code
        (set! g_level_end_reason "\"slain in combat\"")
        (when "killed_by_obstacle")
        (set! g_level_end_reason "\"stumbled into death\""))
      (body-lines
        "function level_end_player_died(killed_by_obstacle)"
        "  g_level_end_reason = \"slain in combat\""
        "\tif killed_by_obstacle then"
        "\t\tg_level_end_reason = \"stumbled into death\""
        "\tend"))
    (def-pico-function
      (name m_splat)
      (params (x y size_base size_var))
      (line-range (1843 1849))
      (api-calls ())
      (called-functions (frnda))
      (structured-ast
        (seq-block 7))
      (decompiled-pseudo-code
        (set! x "x,")
        (set! y "y,")
        (set! size "frnda(size_var, size_base),"))
      (body-lines
        "function m_splat(x, y, size_base, size_var)"
        "\tlocal s ="
        "\t{"
        "\t\tx=x,"
        "\t\ty=y,"
        "\t\tsize=frnda(size_var, size_base),"
        ""))
    (def-pico-function
      (name draw)
      (params (self color))
      (line-range (1850 1855))
      (api-calls (circfill))
      (called-functions ())
      (structured-ast
        (if-cond "color == 0"))
      (decompiled-pseudo-code
        (set! draw "function(self, color)")
        (when "color == 0")
        (call circfill "self.x, self.y, self.size+1, color")
        (call circfill "self.x, self.y, self.size, color"))
      (body-lines
        "\t\tdraw=function(self, color)"
        "\t\t\tif color == 0 then"
        "\t\t\t\tcircfill(self.x, self.y, self.size+1, color)"
        "\t\t\telse"
        "\t\t\t\tcircfill(self.x, self.y, self.size, color)"
        "\t\t\tend"))
    (def-pico-function
      (name m_transition_splatter)
      (params ())
      (line-range (1861 1865))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (seq-block 5))
      (decompiled-pseudo-code
        (set! list_splats "{},"))
      (body-lines
        "function m_transition_splatter()"
        "\tlocal t ="
        "\t{"
        "\t\tlist_splats={},"
        ""))
    (def-pico-function
      (name init)
      (params (self))
      (line-range (1866 1877))
      (api-calls (add rnd))
      (called-functions (frnd frnda m_splat randc))
      (structured-ast
        (while-loop "wipe_position < 128")
        (if-cond "randc("))
      (decompiled-pseudo-code
        (set! init "function(self)")
        (set! wipe_position "0")
        (+= wipe_position "10")
        (call add "self.list_splats, m_splat(wipe_position+2-rnd(4), 48-frnd(6), 10, 8)")
        (call add "self.list_splats, m_splat(wipe_position+2-rnd(4), frnda(6, 80), 10, 8)")
        (when "randc()")
        (call add "self.list_splats, m_splat(wipe_position+4-rnd(8), 30-frnd(15), 2, 5)"))
      (body-lines
        "\t\tinit=function(self)"
        "\t\t\tlocal wipe_position = 0"
        "\t\t\twhile wipe_position < 128 do"
        ""
        "\t\t\t\twipe_position += 10"
        ""
        "\t\t\t\tadd(self.list_splats, m_splat(wipe_position+2-rnd(4), 48-frnd(6), 10, 8))"
        "\t\t\t\tadd(self.list_splats, m_splat(wipe_position+2-rnd(4), frnda(6, 80), 10, 8))"
        ""
        "\t\t\t\tif randc() then"
        "\t\t\t\t\tadd(self.list_splats, m_splat(wipe_position+4-rnd(8), 30-frnd(15), 2, 5))"
        "\t\t\t\tend"))
    (def-pico-function
      (name draw)
      (params (self))
      (line-range (1885 1890))
      (api-calls (all rectfill))
      (called-functions ())
      (structured-ast
        (for-loop "s in all(self.list_splats)"))
      (decompiled-pseudo-code
        (set! draw "function(self)")
        (call rectfill "0, 41, 128, 87, 0")
        (foreach s "self.list_splats")
        (call s:draw "0"))
      (body-lines
        "\t\tdraw=function(self)"
        "\t\t\trectfill(0, 41, 128, 87, 0)"
        ""
        "\t\t\tfor s in all(self.list_splats) do"
        "\t\t\t\ts:draw(0)"
        "\t\t\tend"))
    (def-pico-function
      (name is_level_active)
      (params ())
      (line-range (1903 1906))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "g_game_state == 5 or g_game_state == 6")
        (return-expr "true"))
      (decompiled-pseudo-code
        (when "g_game_state == 5 or g_game_state == 6")
        (return "true"))
      (body-lines
        "function is_level_active()"
        "\tif g_game_state == 5 or g_game_state == 6 then"
        "\t\treturn true"
        "\tend"))
    (def-pico-function
      (name update_weather)
      (params ())
      (line-range (1911 1915))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "g_weather_part_rate == 0")
        (return-expr ""))
      (decompiled-pseudo-code
        (when "g_weather_part_rate == 0")
        (return ""))
      (body-lines
        "function update_weather()"
        "\t---[["
        "\tif g_weather_part_rate == 0 then"
        "\t\treturn"
        "\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1933 1940))
      (api-calls (rnd))
      (called-functions (m_part_sprite randc))
      (structured-ast
        (if-cond "self.y >= self.splash_loc")
        (for-loop "i=0,1")
        (if-cond "randc(50"))
      (decompiled-pseudo-code
        (set! p.update "function(self)")
        (when "self.y >= self.splash_loc")
        (for-range i "0" "1")
        (set! s "m_part_sprite(103, self.x, self.y, -rnd(1), 12, 12, 5, false, true)")
        (set! |s.ddy, s.dx| ".1, rnd(.5)")
        (when "randc(50)")
        (set! s.dx "-rnd(.5)"))
      (body-lines
        "\t\t\t\tp.update=function(self)"
        "\t\t\t\t\tif self.y >= self.splash_loc then"
        "\t\t\t\t\t\tfor i=0,1 do"
        "\t\t\t\t\t\t\tlocal s = m_part_sprite(103, self.x, self.y, -rnd(1), 12, 12, 5, false, true)"
        "\t\t\t\t\t\t\ts.ddy, s.dx = .1, rnd(.5)"
        "\t\t\t\t\t\t\tif randc(50) then"
        "\t\t\t\t\t\t\t\ts.dx = -rnd(.5)"
        "\t\t\t\t\t\t\tend"))
    (def-pico-function
      (name update)
      (params (self))
      (line-range (1947 1951))
      (api-calls (del))
      (called-functions ())
      (structured-ast
        (if-cond "self.y > 128")
        (return-expr ""))
      (decompiled-pseudo-code
        (set! p.update "function(self)")
        (when "self.y > 128")
        (call del "list_parts_front, self")
        (return ""))
      (body-lines
        "\t\t\t\tp.update=function(self)"
        "\t\t\t\t\tif self.y > 128 then"
        "\t\t\t\t\t\tdel(list_parts_front, self)"
        "\t\t\t\t\t\treturn"
        "\t\t\t\t\tend"))
    (def-pico-function
      (name _update60)
      (params ())
      (line-range (1968 1973))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (if-cond "stat(9"))
      (decompiled-pseudo-code
        (+= g_ticks "1")
        (when "stat(9) < stat(8)"))
      (body-lines
        "function _update60()"
        "\tg_ticks += 1"
        "\t--[["
        "\tif stat(9) < stat(8) then"
        "\t--\tprinth(\"dropped frame \"..g_ticks)"
        "\tend"))
    (def-pico-function
      (name fu)
      (params (i))
      (line-range (1976 1976))
      (api-calls ())
      (called-functions (update))
      (structured-ast
        (seq-block 1))
      (decompiled-pseudo-code
        (set! fu "function(i) i:update() end"))
      (body-lines
        "\tlocal fu = function(i) i:update() end"))
    (def-pico-function
      (name level_create)
      (params ())
      (line-range (2167 2178))
      (api-calls ())
      (called-functions (frnd m_player randc))
      (structured-ast
        (if-cond "g_year ~= g_year_endgame")
        (if-cond "g_year ~= 1")
        (if-cond "randc(25"))
      (decompiled-pseudo-code
        (set! p1 "m_player(64,64)")
        (call reload "0x2000, 0x2000, 0x1000")
        (set! |color_choice, block_sel_x, block_sel_y| "g_season, frnd(2), 0")
        (when "g_year ~= g_year_endgame")
        (when "g_year ~= 1")
        (when "randc(25)"))
      (body-lines
        "function level_create()"
        "\tp1 = m_player(64,64)"
        "\treload(0x2000, 0x2000, 0x1000) -- reload original map data"
        ""
        "\tlocal color_choice, block_sel_x, block_sel_y = g_season, frnd(2), 0"
        ""
        "\tif g_year ~= g_year_endgame then"
        "\t\tif g_year ~= 1 then"
        "\t\t\tif randc(25) then"
        "\t\t\t\tg_level_indoor, block_sel_y ="
        "\t\t\t\ttrue, 1"
        "\t\t\tend"))
    (def-pico-function
      (name transition_level)
      (params ())
      (line-range (2269 2278))
      (api-calls (add))
      (called-functions ())
      (structured-ast
        (if-cond "g_season > 3")
        (if-cond "g_year == 7"))
      (decompiled-pseudo-code
        (+= g_season "1")
        (when "g_season > 3")
        (set! g_season "0")
        (+= g_year "1")
        (when "g_year == 7")
        (call add "g_enemy_weights, 5"))
      (body-lines
        "function transition_level()"
        ""
        "\tg_season += 1"
        "\tif g_season > 3 then"
        "\t\tg_season = 0"
        "\t\tg_year += 1"
        ""
        "\t\tif g_year == 7 then"
        "\t\t\tadd(g_enemy_weights, 5)"
        "\t\tend"))
    (def-pico-function
      (name reset_level)
      (params ())
      (line-range (2305 2337))
      (api-calls (flr))
      (called-functions (level_create m_cam table_clear))
      (structured-ast
        (if-cond "g_game_state > 3"))
      (decompiled-pseudo-code
        (set! cam "m_cam()")
        (call table_clear "list_parts_back")
        (call table_clear "list_parts_front")
        (call table_clear "list_parts_blood")
        (call table_clear "list_heads")
        (call table_clear "list_enemies")
        (call table_clear "list_villagers")
        (call table_clear "list_people")
        (call table_clear "list_drawstuff")
        (call table_clear "list_objects")
        (call table_clear "list_steps")
        (when "g_game_state > 3")
        (call level_create ""))
      (body-lines
        "function reset_level()"
        "\tcam=m_cam()"
        "\ttable_clear(list_parts_back)"
        "\ttable_clear(list_parts_front)"
        "\ttable_clear(list_parts_blood)"
        "\ttable_clear(list_heads)"
        "\ttable_clear(list_enemies)"
        "\ttable_clear(list_villagers)"
        "\ttable_clear(list_people)"
        "\ttable_clear(list_drawstuff)"
        "\ttable_clear(list_objects)"
        "\ttable_clear(list_steps)"
        ""
        "\tg_spawned_boss, g_rushmode_ticks,"
        "\tg_ticks, g_transition_to_state, g_transition_time,"
        "\tg_player_damaged_time, g_level_screen_buffer,"
        "\tg_level_villagers_count, g_level_enemies_count, g_level_people_screen_max,"
        "\tg_score_level,"
        "\tgame_pause_timer,"
        "\tg_level_indoor, g_level_night,"
        "\tg_weather_sprite, g_weather_color, g_weather_part_rate, g_weather_wind_shift, g_weather_fall_rate ="
        "\tfalse, 1200+60*g_year,"
        "\t0, 0, 150,"
        "\t0, 16,"
        "\t3+flr(.5*g_year), 7+3*g_year, 4+1*g_year,"
        "\t0,"
        "\t0,"
        "\tfalse, false,"
        "\t0, 0, 0, 0, 0"
        ""
        "\tif g_game_state > 3 then"
        "\t\tlevel_create()"))
    (def-pico-function
      (name reset_game)
      (params ())
      (line-range (2350 2367))
      (api-calls (sfx))
      (called-functions (reset_level shake))
      (structured-ast
        (seq-block 18))
      (decompiled-pseudo-code
        (call split "\"1,1,1,2,2,2,2\"")
        (call reset_level "")
        (call cam:shake "3, 20")
        (call sfx "9"))
      (body-lines
        "function reset_game()"
        "  -- initialized variables, but change during game"
        "\tg_game_state, g_level_end_reason,"
        "\tg_year, g_season,"
        "\tg_score_total,"
        "\tg_level_screen_buffer, g_ticks,"
        "\tg_enemy_weights ="
        "\t0, \"defeated the vandals\","
        "\t1, 0,"
        "\t0,"
        "\t16, 0,"
        "\tsplit(\"1,1,1,2,2,2,2\")"
        ""
        "\treset_level()"
        ""
        "  cam:shake(3, 20)"
        "\tsfx(9)"
        "end"))
    (def-pico-function
      (name _init)
      (params ())
      (line-range (2370 2394))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "i=1,8")
        (for-loop "j=1,2"))
      (decompiled-pseudo-code
        (call cartdata "\"tmirobot_bunbunsamurai_4\"")
        (set! index "1")
        (set! g_high_scores "{}")
        (for-range i "1" "8")
        (set! |g_high_scores[i]| "{}")
        (for-range j "1" "2")
        (set! |g_high_scores[i][j]| "dget(index)")
        (+= index "1"))
      (body-lines
        "function _init()"
        "\tcartdata(\"tmirobot_bunbunsamurai_4\")"
        "\tg_alphabet_sprites,"
        "\tg_season_names,"
        "\tg_weather_seasondata,"
        "\tg_difficulty_strings,"
        "\tg_difficulty_descs,"
        "\tg_year_endgame,"
        "\tg_difficulty ="
        "\tsplit(\"a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,0,1,2,3,4,5,6,7,8,9\", \",\", false),"
        "\tsplit(\"spring,summer,fall,winter,140,142,172,174\"),"
        "\tsplit(\"119,12,1,0,3,121,14,6,.05,.5,123,9,6,.05,.5,121,6,1,.1,1\"),"
        "\tsplit(\"easy,easy,norm,norm,hard,hard,hell,hell\"),"
        "\tsplit(\"enemy strikes deal damage,s,enemy touches deal damage,s,hero dies from a single hit,s,villager death ends the game,s\"),"
        "\t10,"
        "\t3"
        ""
        "\tlocal index = 1"
        "\tg_high_scores = {}"
        "\tfor i=1,8 do"
        "\t\tg_high_scores[i] = {}"
        "\t\tfor j=1,2 do"
        "\t\t\tg_high_scores[i][j] = dget(index)"
        "\t\t\tindex += 1"
        "\t\tend"))
    (def-pico-function
      (name sort_by_y)
      (params (t))
      (line-range (2400 2406))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (for-loop "n=2,#t")
        (while-loop "i>1 and t[i].y<t[i-1].y"))
      (decompiled-pseudo-code
        (for-range n "2" "#t")
        (set! i "n")
        (-= i "1"))
      (body-lines
        "function sort_by_y(t) --insertion sort, ascending y"
        "  for n=2,#t do"
        "    local i=n"
        "    while i>1 and t[i].y<t[i-1].y do"
        "      t[i],t[i-1]=t[i-1],t[i]"
        "      i-=1"
        "    end"))
    (def-pico-function
      (name is_timed_mode)
      (params ())
      (line-range (2410 2412))
      (api-calls ())
      (called-functions ())
      (structured-ast
        (return-expr "g_difficulty % 2 == 0"))
      (decompiled-pseudo-code
        (return "g_difficulty % 2 == 0"))
      (body-lines
        "function is_timed_mode()"
        "\treturn g_difficulty % 2 == 0"
        "end"))
    (def-pico-function
      (name _draw)
      (params ())
      (line-range (2414 2422))
      (api-calls (all))
      (called-functions (draw paste_screen_from_mem))
      (structured-ast
        (if-cond "g_game_state > 3 and g_game_state < 10")
        (for-loop "a in all(list_parts_blood)")
        (if-cond "a.time == a.duration"))
      (decompiled-pseudo-code
        (when "g_game_state > 3 and g_game_state < 10")
        (call paste_screen_from_mem "")
        (foreach a "list_parts_blood")
        (when "a.time == a.duration")
        (call a:draw ""))
      (body-lines
        "function _draw()"
        ""
        "\tif g_game_state > 3 and g_game_state < 10 then"
        "\t\tpaste_screen_from_mem ()"
        ""
        "\t\tfor a in all(list_parts_blood) do"
        "\t\t\tif a.time == a.duration then"
        "\t\t\t\ta:draw()"
        "\t\t\tend"))
    (def-pico-function
      (name fd)
      (params (i))
      (line-range (2442 2442))
      (api-calls ())
      (called-functions (draw))
      (structured-ast
        (seq-block 1))
      (decompiled-pseudo-code
        (set! fd "function(i) i:draw() end"))
      (body-lines
        "\t\tlocal fd = function(i) i:draw() end")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id 0 #:grid (0 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00700700" "00077000" "00077000" "00700700" "00000000" "00000000"))
      (def-pico-sprite #:id 1 #:grid (1 0) #:nonzero-pixels 37 #:rows ("00000000" "00202000" "02424200" "02424200" "28888820" "024c4c20" "02777720" "22667200"))
      (def-pico-sprite #:id 2 #:grid (2 0) #:nonzero-pixels 32 #:rows ("00000000" "00000000" "00202000" "02424200" "29999920" "02484820" "02999920" "22669200"))
      (def-pico-sprite #:id 3 #:grid (3 0) #:nonzero-pixels 30 #:rows ("00000000" "00000000" "00000000" "02222200" "2aaaaa20" "025c5c20" "02aa9920" "22665200"))
      (def-pico-sprite #:id 4 #:grid (4 0) #:nonzero-pixels 38 #:rows ("00000000" "00000000" "02202200" "24424420" "28888820" "024a4a20" "02888442" "22888220"))
      (def-pico-sprite #:id 5 #:grid (5 0) #:nonzero-pixels 46 #:rows ("00000000" "02202200" "2dd2dd20" "2dd2dd20" "2eeeee20" "02dadad2" "02eeedd2" "22eee220"))
      (def-pico-sprite #:id 6 #:grid (6 0) #:nonzero-pixels 46 #:rows ("00200200" "02822820" "028dd820" "02dddd20" "021a1ad2" "02ddddd2" "02dddd20" "0266dd20"))
      (def-pico-sprite #:id 7 #:grid (7 0) #:nonzero-pixels 30 #:rows ("00000000" "00000000" "00202000" "02626200" "02626200" "02666620" "026b6b20" "02666620"))
      (def-pico-sprite #:id 12 #:grid (12 0) #:nonzero-pixels 16 #:rows ("26677772" "02272720" "00020200" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 13 #:grid (13 0) #:nonzero-pixels 16 #:rows ("26677772" "02227720" "00002200" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 14 #:grid (14 0) #:nonzero-pixels 17 #:rows ("26677772" "02272272" "00020020" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 15 #:grid (15 0) #:nonzero-pixels 16 #:rows ("26677772" "02222272" "00000020" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 17 #:grid (1 1) #:nonzero-pixels 44 #:rows ("00000000" "00222220" "02666662" "02427272" "28888820" "024c4c20" "02777720" "02777220"))
      (def-pico-sprite #:id 18 #:grid (2 1) #:nonzero-pixels 43 #:rows ("00000000" "00222220" "02666662" "02429292" "29999920" "02484820" "02999920" "02999200"))
      (def-pico-sprite #:id 19 #:grid (3 1) #:nonzero-pixels 43 #:rows ("00000000" "00222220" "02666662" "0222a2a2" "2aaaaa20" "025c5c20" "02aa9920" "02aaa200"))
      (def-pico-sprite #:id 20 #:grid (4 1) #:nonzero-pixels 38 #:rows ("00020000" "00262000" "00027200" "00255520" "02555552" "02555552" "02555552" "00255520"))
      (def-pico-sprite #:id 21 #:grid (5 1) #:nonzero-pixels 46 #:rows ("00000000" "02202200" "2dd2dd20" "2dd2dd20" "2eeeee20" "02dadad2" "02eeedd2" "22eee220"))
      (def-pico-sprite #:id 22 #:grid (6 1) #:nonzero-pixels 51 #:rows ("00222220" "02666662" "028dd8d2" "02dddd20" "021a1ad2" "02ddddd2" "02dddd20" "02dddd20"))
      (def-pico-sprite #:id 23 #:grid (7 1) #:nonzero-pixels 32 #:rows ("00000000" "00000000" "00202000" "02626200" "02626200" "02666620" "266b6b62" "02661620"))
      (def-pico-sprite #:id 24 #:grid (8 1) #:nonzero-pixels 32 #:rows ("00000000" "00000000" "00202000" "02626200" "02626200" "026b6b20" "02661620" "26661662"))
      (def-pico-sprite #:id 28 #:grid (12 1) #:nonzero-pixels 13 #:rows ("00277772" "00272720" "00020200" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 29 #:grid (13 1) #:nonzero-pixels 12 #:rows ("00277772" "00027720" "00002200" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 30 #:grid (14 1) #:nonzero-pixels 14 #:rows ("00277772" "00272272" "00020020" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 31 #:grid (15 1) #:nonzero-pixels 12 #:rows ("00277772" "00022272" "00000020" "00000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 33 #:grid (1 2) #:nonzero-pixels 37 #:rows ("00000000" "00202000" "02424200" "02424200" "28888820" "024c4c20" "02777720" "02777220"))
      (def-pico-sprite #:id 34 #:grid (2 2) #:nonzero-pixels 32 #:rows ("00000000" "00000000" "00202000" "02424200" "29999920" "02484820" "02999920" "02999220"))
      (def-pico-sprite #:id 35 #:grid (3 2) #:nonzero-pixels 30 #:rows ("00000000" "00000000" "00000000" "02222200" "2aaaaa20" "025c5c20" "02aa9920" "02aaa220"))
      (def-pico-sprite #:id 37 #:grid (5 2) #:nonzero-pixels 46 #:rows ("00000000" "02202200" "2dd2dd20" "2dd2dd20" "2eeeee20" "02dadad2" "02eeedd2" "22eee220"))
      (def-pico-sprite #:id 38 #:grid (6 2) #:nonzero-pixels 46 #:rows ("00200200" "02822820" "028dd820" "02dddd20" "021a1ad2" "02ddddd2" "02dddd20" "02dddd20"))
      (def-pico-sprite #:id 40 #:grid (8 2) #:nonzero-pixels 23 #:rows ("00000000" "00000000" "02000000" "28222220" "02777772" "28222220" "02000000" "00000000"))
      (def-pico-sprite #:id 41 #:grid (9 2) #:nonzero-pixels 23 #:rows ("00002000" "00027200" "00027200" "00027200" "00027200" "00027200" "00282820" "00020200"))
      (def-pico-sprite #:id 42 #:grid (10 2) #:nonzero-pixels 30 #:rows ("00000000" "00222200" "02668620" "00266820" "00268820" "02666820" "00222200" "00000000")))
    (gff-flags
      (def-pico-sprite-flag #:id 135 #:flags 29)
      (def-pico-sprite-flag #:id 136 #:flags 1)
      (def-pico-sprite-flag #:id 138 #:flags 56)
      (def-pico-sprite-flag #:id 150 #:flags 255)
      (def-pico-sprite-flag #:id 151 #:flags 255)
      (def-pico-sprite-flag #:id 152 #:flags 255)
      (def-pico-sprite-flag #:id 153 #:flags 255)
      (def-pico-sprite-flag #:id 154 #:flags 255)
      (def-pico-sprite-flag #:id 166 #:flags 255)
      (def-pico-sprite-flag #:id 167 #:flags 255)
      (def-pico-sprite-flag #:id 168 #:flags 255)
      (def-pico-sprite-flag #:id 169 #:flags 255)
      (def-pico-sprite-flag #:id 170 #:flags 255)
      (def-pico-sprite-flag #:id 182 #:flags 255)
      (def-pico-sprite-flag #:id 183 #:flags 255)
      (def-pico-sprite-flag #:id 184 #:flags 255)
      (def-pico-sprite-flag #:id 185 #:flags 255)
      (def-pico-sprite-flag #:id 186 #:flags 255)
      (def-pico-sprite-flag #:id 187 #:flags 255)
      (def-pico-sprite-flag #:id 188 #:flags 255)
      (def-pico-sprite-flag #:id 189 #:flags 255))
    (map-rows
      (def-pico-map-row #:y 0 #:nonzero-tiles 3 #:sample-hex "00000000000000000000009100000000")
      (def-pico-map-row #:y 1 #:nonzero-tiles 7 #:sample-hex "00a0000000000000000000000000a000")
      (def-pico-map-row #:y 2 #:nonzero-tiles 6 #:sample-hex "00000000920000000000000000000000")
      (def-pico-map-row #:y 3 #:nonzero-tiles 7 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 4 #:nonzero-tiles 8 #:sample-hex "00000000a0000000000000a000920000")
      (def-pico-map-row #:y 5 #:nonzero-tiles 1 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 6 #:nonzero-tiles 2 #:sample-hex "00009100000000000000000000000000")
      (def-pico-map-row #:y 7 #:nonzero-tiles 4 #:sample-hex "0000000000009200000000000000a000")
      (def-pico-map-row #:y 8 #:nonzero-tiles 2 #:sample-hex "00a00000000000000000000000000000")
      (def-pico-map-row #:y 9 #:nonzero-tiles 2 #:sample-hex "00000000000000000000000000000092")
      (def-pico-map-row #:y 10 #:nonzero-tiles 2 #:sample-hex "00000000000000000092000000000000")
      (def-pico-map-row #:y 11 #:nonzero-tiles 12 #:sample-hex "00000000a0000000000000a000000000")
      (def-pico-map-row #:y 12 #:nonzero-tiles 10 #:sample-hex "00000091000000000000000000000000")
      (def-pico-map-row #:y 13 #:nonzero-tiles 10 #:sample-hex "00000000000000000000000091000000")
      (def-pico-map-row #:y 14 #:nonzero-tiles 14 #:sample-hex "00a00000000000a0000000000000a000")
      (def-pico-map-row #:y 15 #:nonzero-tiles 2 #:sample-hex "00009200000000000000000000000000")
      (def-pico-map-row #:y 16 #:nonzero-tiles 32 #:sample-hex "80808080808080808080808080808080")
      (def-pico-map-row #:y 17 #:nonzero-tiles 32 #:sample-hex "80808282828282828282828282828080")
      (def-pico-map-row #:y 18 #:nonzero-tiles 32 #:sample-hex "8081a090909090909090909090a08180")
      (def-pico-map-row #:y 19 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 20 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 21 #:nonzero-tiles 32 #:sample-hex "8081909090a090909090a09090908180")
      (def-pico-map-row #:y 22 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 23 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 24 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 25 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 26 #:nonzero-tiles 32 #:sample-hex "8081909090a090909090a09090908180")
      (def-pico-map-row #:y 27 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 28 #:nonzero-tiles 32 #:sample-hex "80819090909090909090909090908180")
      (def-pico-map-row #:y 29 #:nonzero-tiles 32 #:sample-hex "8081a090909090909090909090a08180")
      (def-pico-map-row #:y 30 #:nonzero-tiles 32 #:sample-hex "80808282828282828282828282828080")
      (def-pico-map-row #:y 31 #:nonzero-tiles 32 #:sample-hex "80808080808080808080808080808080"))
    (sfx-tracks
      (def-pico-sfx #:id 0 #:editor-mode 1 #:speed 1 #:loop (0 0) #:active-notes 4)
      (def-pico-sfx #:id 1 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 2 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 13)
      (def-pico-sfx #:id 3 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 4 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 5 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 14)
      (def-pico-sfx #:id 6 #:editor-mode 1 #:speed 0 #:loop (0 0) #:active-notes 13)
      (def-pico-sfx #:id 7 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 15)
      (def-pico-sfx #:id 8 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 14)
      (def-pico-sfx #:id 9 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 27)
      (def-pico-sfx #:id 10 #:editor-mode 1 #:speed 2 #:loop (0 0) #:active-notes 17)
      (def-pico-sfx #:id 11 #:editor-mode 63 #:speed 22 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 12 #:editor-mode 63 #:speed 22 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 13 #:editor-mode 62 #:speed 22 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 14 #:editor-mode 62 #:speed 22 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 15 #:editor-mode 62 #:speed 20 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 16 #:editor-mode 0 #:speed 6 #:loop (0 0) #:active-notes 2)
      (def-pico-sfx #:id 17 #:editor-mode 104 #:speed 2 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 18 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 9)
      (def-pico-sfx #:id 19 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 9)
      (def-pico-sfx #:id 20 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 8)
      (def-pico-sfx #:id 21 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 11)
      (def-pico-sfx #:id 22 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 9)
      (def-pico-sfx #:id 23 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 10)
      (def-pico-sfx #:id 24 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 6)
      (def-pico-sfx #:id 25 #:editor-mode 0 #:speed 1 #:loop (0 0) #:active-notes 11)
      (def-pico-sfx #:id 26 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 27 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 28 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 29 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 30 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 31 #:editor-mode 0 #:speed 0 #:loop (0 0) #:active-notes 12))
    (music-patterns
      (def-pico-music #:pattern 0 #:flags 2 #:channels (14 64 64 64))
      (def-pico-music #:pattern 1 #:flags 0 #:channels (14 0 0 0))
      (def-pico-music #:pattern 2 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 3 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 4 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 5 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 6 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 7 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 8 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 9 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 10 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 11 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 12 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 13 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 14 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 15 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 16 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 17 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 18 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 19 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 20 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 21 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 22 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 23 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 24 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 25 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 26 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 27 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 28 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 29 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 30 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 31 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 32 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 33 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 34 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 35 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 36 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 37 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 38 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 39 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 40 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 41 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 42 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 43 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 44 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 45 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 46 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 47 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 48 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 49 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 50 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 51 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 52 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 53 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 54 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 55 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 56 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 57 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 58 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 59 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 60 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 61 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 62 #:flags 0 #:channels (0 0 0 0))
      (def-pico-music #:pattern 63 #:flags 0 #:channels (0 0 0 0))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      ""
      "list_enemies = {}"
      "list_villagers = {}"
      "list_people = {}"
      "list_drawstuff = {}"
      "list_objects = {}"
      "list_parts_back = {}"
      "list_parts_front = {}"
      "list_parts_blood = {}"
      "list_steps = {}"
      "list_heads = {}"
      ""
      "function frnd(n)"
      "\treturn flr(rnd(n))"
      "end"
      ""
      "function frnda(n, o)"
      "\tlocal addval = o or 1"
      "\treturn frnd(n)+addval"
      "end"
      ""
      "function randc(chance)"
      "\tlocal c = chance or 50"
      "\tif frnd(100) < c then"
      "\t\treturn true"
      "\tend"
      "\treturn false"
      "end"
      ""
      "function wrap(value, min, max)"
      "\tif value < min then"
      "\t\treturn max"
      "\telseif value > max then"
      "\t\treturn min"
      "\telse"
      "\t\treturn value"
      "\tend"
      "end"
      ""
      "function table_clear(t)"
      "\tlocal count = #t"
      "\tfor i=0, count do t[i]=nil end"
      "end"
      ""
      "function copy_screen_to_mem()"
      "\t-- half the map/lower sprite memory area"
      "\tmemcpy(0x1800, 0x6000, 0x0800)"
      "\t-- almost all general use memory"
      "\tmemcpy(0x4300, 0x6800, 0x1800)"
      "end"
      ""
      "function paste_screen_from_mem()"
      "\tmemcpy(0x6000, 0x1800, 0x0800)"
      "\tmemcpy(0x6800, 0x4300, 0x1800)"
      "end"
      ""
      "function printc_o(str, y, col, outcol, x) -- print a centered string with a black outline"
      "\tfor i=-1,1 do"
      "\t \tfor j=-1,1 do"
      "\t   \tprintc(str, y+j, outcol or 2, (x or 64)+i)"
      "\t \tend"
      "\tend"
      "\tprintc(str, y, col, (x or 64))"
      "end"
      ""
      "function printc(str, y, col, x)"
      "\tprint(str, (x or 64)-#str*2, y, col or 7)"
      "end"
      ""
      ""
      "function printsprite(str, y, color)"
      "\tpal(7, color)"
      "\tfor i=1, #str do"
      ""
      "\t\tlocal letter, whichalpha = sub(str,i,i), -1"
      "\t\tfor j in all(g_alphabet_sprites) do"
      "\t\t\twhichalpha += 1"
      "\t\t\tif letter == j then"
      "\t\t\t\tspr(131 + flr(whichalpha/9)*16 + whichalpha % 9, 64-(#str*8)/2 + (i-1)*8, y)"
      "\t\t\t\tbreak"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "\tpal()"
      "end"
      ""
      "function set_outline()"
      "\tpal(2, g_color_outline)"
      "end"
      ""
      "function m_textfloat(x,y, text, col_main, col_sec)"
      "\tadd(list_parts_front,"
      "\t{"
      "\t\tx=x,"
      "\t\ty=y,"
      "\t\ttext=text,"
      "\t\tcol_main=col_main or 7,"
      "\t\tcol_sec=col_sec or 5,"
      "\t\tdur=30,"
      "\t\tdur_orig=30,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tlocal color = self.col_main"
      "\t\t\tif self.dur < self.dur_orig/3 then"
      "\t\t\t\tcolor = self.col_sec"
      "\t\t\tend"
      "\t\t\tprintc_o(self.text, self.y, color, g_color_outline, self.x)"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tself.dur-=1"
      "\t\t\tif self.dur == 0 then"
      "\t\t\t\tdel(list_parts_front, self)"
      "\t\t\telse"
      "\t\t\t\tself.y -= .3"
      "\t\t\tend"
      "\t\tend,"
      "\t})"
      "end"
      ""
      "function a_set_invuln_flash(self)"
      "\tif self.invuln_frames > 0 and self.invuln_frames % 5 < 3 then"
      "\t\tfor i=1,15 do"
      "\t\t\tpal(i, 2)"
      "\t\tend"
      "\t\treturn true"
      "\tend"
      "\treturn false"
      "end"
      ""
      "function is_near_objs(obj1, obj2, range)"
      "\tif abs(obj1.x-obj2.x) <= range and abs(obj1.y-obj2.y) <= range then"
      "\t\treturn true"
      "\tend"
      "\treturn false"
      "end"
      ""
      "function int_cols(e1, e2, buffer)"
      "\tif e1.just_spawned or e2.just_spawned then"
      "\t\treturn false"
      "\tend"
      "\tlocal buffer = buffer or 0"
      "\tlocal x1, y1, w1, h1, x2, y2, w2, h2 ="
      "\t\t\t\te1.x-e1.col_w/2-buffer,"
      "\t\t\t\te1.y-e1.col_h/2-buffer,"
      "\t\t\t \te1.col_w+buffer*2,"
      "\t\t\t \te1.col_h+buffer*2,"
      "\t\t\t\te2.x-e2.col_w/2-buffer,"
      "\t\t\t\te2.y-e2.col_h/2-buffer,"
      "\t\t\t\te2.col_w+buffer*2,"
      "\t\t\t\te2.col_h+buffer*2"
      "\tif x1+w1<x2 or x2+w2<x1 or y1+h1<y2 or y2+h2<y1 then"
      "    return false"
      "\telse"
      "  \treturn true"
      "\tend"
      "end"
      ""
      "function m_part_blood(part_details, duration)"
      "\tpart_details[6] = duration or frnda(10, 50)"
      "\tm_part_angle(part_details, .65, 8, g_color_blood_burn)"
      "end"
      ""
      "function m_part_angle(part_details, frict, color, color_sec, layer)"
      ""
      "\tlocal p ="
      "\t{"
      "\t\tsize=part_details[1]-1,"
      "\t\tx=part_details[2],"
      "\t\ty=part_details[3],"
      "\t\tangle=part_details[4],"
      "\t\tspeed_move=part_details[5],"
      "\t\tduration=part_details[6],"
      "\t\tfrict=frict,"
      "\t\tcolor=color,"
      "\t\tcolor_sec=color_sec or color,"
      "\t\tlayer=layer or 0,"
      ""
      "\t\ttime=0,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tlocal color, s2 = self.color, self.size/2"
      "\t\t\tif self.time > self.duration *.75 then"
      "\t\t\t\tcolor = self.color_sec"
      "\t\t\tend"
      "\t\t\tif self.size == 0 then"
      "\t\t\t\tpset(self.x, self.y, color)"
      "\t\t\telse"
      "\t\t\t\trectfill(self.x-s2, self.y-s2, self.x+s2, self.y+s2, color)"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tif self.time > self.duration then"
      "\t\t\t\tif self.layer == 1 then"
      "\t\t\t\t\tdel(list_parts_back, self)"
      "\t\t\t\telseif self.layer == 2 then"
      "\t\t\t\t\tdel(list_parts_front, self)"
      "\t\t\t\telse"
      "\t\t\t\t\tdel(list_parts_blood, self)"
      "\t\t\t\tend"
      ""
      "\t\t\t\treturn"
      "\t\t\tend"
      "\t\t\tif self.speed_move > .1 then"
      "\t\t\t\ta_move_angle(self)"
      "\t\t\t\tself.speed_move *= self.frict"
      "\t\t\tend"
      "\t\t\tself.time += 1"
      "\t\tend,"
      "\t}"
      "\tif layer == 1 then"
      "\t\tadd(list_parts_back, p)"
      "\telseif layer == 2 then"
      "\t\tadd(list_parts_front, p)"
      "\telse"
      "\t\tadd(list_parts_blood, p)"
      "\tend"
      "\treturn p"
      "end"
      ""
      "function m_part_sprite(frame, x,y, dy, col, col_sec, duration, flipx, is_front)"
      ""
      "\tlocal p ="
      "\t{"
      "\t\tx=x,"
      "\t\ty=y,"
      "\t\tframe=frame,"
      "\t\tcol=col,"
      "\t\tcol_sec=col_sec or col,"
      "\t\tduration=duration,"
      "\t\tflipx=flipx or false,"
      "\t\tis_front=is_front or false,"
      ""
      "\t\ttime=0,"
      "\t\tdx=0,"
      "\t\tdy=dy,"
      "\t\tddy=0,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tif self.time < self.duration *.75 then"
      "\t\t\t\tpal(7,self.col)"
      "\t\t\telse"
      "\t\t\t\tpal(7,self.col_sec)"
      "\t\t\tend"
      "\t\t\tspr(self.frame, self.x-4, self.y-4, 1, 1, self.flipx)"
      "\t\t\tpal()"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tself:update_base()"
      "\t\tend,"
      ""
      "\t\tupdate_base=function(self)"
      "\t\t\tif self.time > self.duration then"
      "\t\t\t\tif self.is_front then"
      "\t\t\t\t\tdel(list_parts_front, self)"
      "\t\t\t\telse"
      "\t\t\t\t\tdel(list_parts_back, self)"
      "\t\t\t\tend"
      "\t\t\t\treturn"
      "\t\t\tend"
      "\t\t\tself.x += self.dx"
      "\t\t\tself.y += self.dy"
      "\t\t\tself.dy += self.ddy"
      "\t\t\tself.time += 1"
      "\t\tend,"
      "\t}"
      "\tif is_front then"
      "\t\tadd(list_parts_front, p)"
      "\telse"
      "\t\tadd(list_parts_back, p)"
      "\tend"
      "\treturn p"
      "end"
      ""
      "function m_part_bomb_spark(x, y)"
      "\tlocal color, color_second = 10, 9"
      "\tif randc() then"
      "\t\tcolor, color_second = 7, 10"
      "\tend"
      "\tlocal p = m_part_sprite(103, x, y, -.2-rnd(.5), color, color_second, 10+rnd(5), false, true)"
      "\tp.ddy = .1"
      "\tlocal dx = rnd(.5)"
      "\tif randc() then"
      "\t\tdx = 0 - dx"
      "\tend"
      "\tp.dx = dx"
      "end"
      ""
      "function m_part_circle(x,y, size, duration, color, color_sec, layer)"
      ""
      "\tlocal p = m_part_angle({size, x, y, 0, 0, duration}, 0, color, color_sec, layer)"
      "\tp.draw=function(self)"
      "\t\tlocal color = self.color"
      "\t\tif self.time > self.duration * .75 then"
      "\t\t\tcolor = self.color_sec"
      "\t\tend"
      "\t\tcircfill(self.x, self.y, self.size, color)"
      "\tend"
      "end"
      ""
      "function m_part_bloodsplash(x,y,angle)"
      ""
      "\tfor i=0,36 do"
      "\t\tlocal size, xoff, yoff, angleoff,dur=1, rnd(4), rnd(4), rnd(.2), rnd(8)"
      "\t\tif i > 30 then"
      "\t\t\tdur=rnd(1)"
      "\t\t\tsize=2"
      "\t\telseif i > 15 then"
      "\t\t\tdur=rnd(4)"
      "\t\tend"
      "\t\tm_part_blood({size, x-2+xoff, y-2+yoff, angle-.1+angleoff, dur})"
      "\tend"
      ""
      "end"
      ""
      "function m_part_impact(entity,size)"
      "\tm_part_circle(entity.x, entity.y, size or 7, 4, 10, 9, 1)"
      "end"
      ""
      "function handle_slash_recovery(speed)"
      "\tlocal dir = rnd(.125)"
      "\tif randc() then"
      "\t\tdir = 0-dir"
      "\tend"
      ""
      "\tp1.slash_angle, p1.slash_speed, p1.slash_time, p1.slash_has_impacted ="
      "\tabs(p1.slash_angle+.5+dir)%1, speed or 0, 5, true"
      "\ta_anim_set(p1, \"attack\")"
      "end"
      ""
      "function handle_slash_entity_impact(target)"
      ""
      "\tcam:shake(.1, 3)"
      "  game_pause(2, 0)"
      "\tif not target.is_furniture then"
      "\t\tm_part_bloodsplash(target.x, target.y, p1.slash_angle)"
      "\tend"
      ""
      "\tm_part_impact(target, 10)"
      "\thandle_slash_recovery()"
      "end"
      ""
      "function score_add(entity, score)"
      "\tif score > 0 then"
      "\t\tsfx(min(26+flr(score/1), 31))"
      "\telse"
      "\t\tsfx(32)"
      "\tend"
      ""
      "  g_score_level += score"
      ""
      "  local score_color, score_color_sec = 10, 9"
      "  if score >= 4 then"
      "    score_color, score_color_sec = 7, 9"
      "  elseif score >= 2 then"
      "    score_color, score_color_sec = 11, 3"
      "\telseif score < 0 then"
      "\t\tscore_color, score_color_sec = 8, 13"
      "  end"
      "\tif score != 0 then"
      "  \tm_textfloat(entity.x, entity.y-8, \"\"..score*10, score_color, score_color_sec)"
      "\tend"
      "end"
      ""
      "function attempt_deflect_target(target)"
      ""
      "\tlocal reverse_angle = abs(target.angle+.5)%1"
      ""
      "\tif abs(p1.slash_angle - reverse_angle) < .25 then"
      ""
      "\t\tsfx(8)"
      "\t\tm_part_circle(target.x, target.y, 6, 10, 7, 5, 1)"
      ""
      "\t\ttarget.is_flying, target.is_flying_impactable, target.windup_time_rem, target.attack_time_rem, target.fly_speed ="
      "\t\ttrue, false, 0, 0, 2"
      ""
      "\t\tlocal t_dir = rnd(.125)"
      "\t\tif randc() then"
      "\t\t\tt_dir = 0 - t_dir"
      "\t\tend"
      "\t\ttarget.angle= abs(p1.slash_angle+t_dir)%1"
      "\t\t--target:emotion_add()"
      ""
      "\t\t-- todo - combine this with handle-impact version into a single function"
      ""
      "\t\thandle_slash_recovery(2)"
      "\t\treturn true"
      "\tend"
      "\treturn false"
      "end"
      ""
      "function combo(entity, target)"
      "\tentity.was_counted_for_combo = true"
      ""
      "\tsfx(frnda(2, 21))"
      "\thandle_impact_death(entity, target)"
      ""
      "\tif not entity.is_furniture then"
      "\t\tm_part_bloodsplash(target.x, target.y, entity.angle)"
      "\tend"
      ""
      "\ttarget:handle_impact(entity)"
      "\ttarget.fly_speed, target.angle = entity.fly_speed, entity.angle%1"
      ""
      "\tif entity.is_heavy or entity.is_armored then"
      "\t\ttarget.score_multiplier = entity.score_multiplier"
      "\t\tfly_reset(entity)"
      "\t\tentity.invuln_frames = 15"
      "\t\tif entity.is_armored then"
      "\t\t\tattack_reset(entity)"
      "\t\tend"
      "\telse"
      "\t\ttarget.score_multiplier = entity.score_multiplier + 1"
      "\tend"
      "end"
      ""
      "function slash_target(target)"
      ""
      "\tsfx(25)"
      "\ttarget.fly_speed, target.angle = 3, p1.slash_angle"
      "\ttarget:handle_impact()"
      "\thandle_slash_entity_impact(target)"
      "\ta_anim_set(p1, \"attack\")"
      "end"
      ""
      "function a_anim_update(entity, anim_set, tick_multiplier)"
      "\tif tick_multiplier == nil then"
      "\t\ttick_multiplier = 1"
      "\tend"
      "\tentity.animtick-=1 * tick_multiplier"
      "\tif entity.animtick<=0 then"
      "\t\tentity.curframe+=1"
      "\t\tlocal a=anim_set[entity.curanim]"
      ""
      "\t\tentity.animtick=a.ticks"
      "\t\tif entity.curframe>#a.frames then"
      "\t\t\tentity.curframe=1"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function a_anim_set(entity, anim)"
      "\tif(anim==entity.curanim)return"
      ""
      "\tentity.animtick, entity.curanim, entity.curframe = character_anims[anim].ticks, anim, 1"
      "end"
      ""
      "function a_doflipx(entity)"
      "\tlocal angle = entity.angle"
      "\tif angle == .25 or angle == .75 then"
      "\t\treturn"
      "\telseif angle > .25 and angle < .75 then"
      "\t\tentity.flipx = true"
      "\telse"
      "\t\tentity.flipx = false"
      "\tend"
      "end"
      ""
      "function constrain_to_screen(obj)"
      "\treturn constrain_to_borders(obj, g_level_screen_buffer+4, g_level_screen_buffer+4, 124-g_level_screen_buffer, 124-g_level_screen_buffer)"
      "end"
      ""
      "function constrain_to_borders(obj, bor_x1, bor_y1, bor_x2, bor_y2)"
      ""
      "\tlocal was_constrained, x, y = false, obj.x, obj.y"
      "\tif x < bor_x1 then"
      "\t\tx, was_constrained = bor_x1, true"
      "\telseif x > bor_x2 then"
      "\t\tx, was_constrained = bor_x2, true"
      "\tend"
      "\tif y < bor_y1 then"
      "\t\ty, was_constrained = bor_y1, true"
      "\telseif y > bor_y2 then"
      "\t\ty, was_constrained = bor_y2, true"
      "\tend"
      "\tobj.x, obj.y = x, y"
      "\treturn was_constrained"
      "end"
      ""
      "function game_pause(duration)"
      "\tgame_pause_timer = duration"
      "end"
      ""
      "function handle_impact_death(entity, target)"
      "\tif not entity.is_furniture and not entity.is_armored then"
      "\t\tsplit_entity(entity, (entity.angle+.5)%1)"
      "\t\tm_part_bloodsplash(target.x, target.y, entity.angle)"
      "\t\tif target.is_heavy then"
      "\t\t\tif not target.is_bloody then"
      "\t\t\t\ttarget.sprite += 16"
      "\t\t\t\ttarget.is_bloody = true"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "\tm_part_impact(entity)"
      "\tcam:shake(.5*entity.fly_speed,10)"
      "  game_pause(2)"
      ""
      "\tif entity.is_villager then"
      "\t\tlevel_end_villager_died(false)"
      "\tend"
      "\tif not entity.is_heavy and not entity.is_armored then"
      "  \tdel_from_people(entity)"
      "\t\tscore_add(entity, entity.score * entity.score_multiplier)"
      "\tend"
      "end"
      ""
      "function fly_reset(entity)"
      "\tentity.fly_speed, entity.is_flying, entity.is_flying_impactable, entity.angle, entity.score_multiplier ="
      "\t0, false, false, get_dir_to_player(entity), 1"
      "end"
      ""
      "function attack_reset(entity)"
      "\tentity.attack_time_rem, entity.recovery_time_rem, entity.time_between_attacks_rem ="
      "\t0, entity.recovery_time, entity.time_between_attacks+entity.recovery_time"
      "end"
      ""
      "function a_attack(entity)"
      ""
      "\tentity.attack_time_rem -= 1"
      "\ta_move_angle(entity, 4)"
      "\tif constrain_to_screen(entity) then"
      "\t\tsfx(20)"
      "\t\tattack_reset(entity)"
      "\tend"
      ""
      "\tif entity.attack_time_rem <= 0 then"
      "\t\tattack_reset(entity)"
      "\tend"
      "end"
      ""
      "function a_fly(entity)"
      "\ta_move_angle(entity, entity.fly_speed)"
      "\tentity.fly_speed *= .95"
      ""
      "\tlocal was_reset = false"
      ""
      "  if entity.fly_speed <= .1 then"
      "\t\tfly_reset(entity)"
      "\t\twas_reset = true"
      "  end"
      ""
      "\tif constrain_to_screen(entity) then"
      "\t\tentity.angle, entity.fly_speed = get_rebound_angle_speed(entity.angle, entity.fly_speed)"
      "\t\tm_part_impact(entity)"
      "\t\tentity.is_flying_impactable = false"
      "\t\tsfx(23)"
      "\tend"
      ""
      "\tif not was_reset and entity.is_flying_impactable then"
      "\t\tfor a in all(list_people) do"
      "\t\t--\tif not a.is_flying then"
      "\t\t\t\tif entity != a and a.invuln_frames == 0 and int_cols(entity, a, 2) then"
      "\t\t\t\t\tif entity.fly_speed > .5 then"
      "\t\t\t\t\t\tcombo(entity,a)"
      "\t\t\t\t\t\tbreak"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t--\tend"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function a_move_angle(entity, speed)"
      "\tif not speed then"
      "\t\tspeed = entity.speed_move"
      "\tend"
      ""
      "\tentity.angle = abs(entity.angle)%1"
      "\ta_doflipx(entity)"
      ""
      "\tentity.x += cos(entity.angle) * speed"
      "\tentity.y += sin(entity.angle) * speed"
      "end"
      ""
      "character_anims ="
      "{"
      "\t[\"stand\"]="
      "\t{"
      "\t\tticks=10000,"
      "\t\thframes={1},"
      "\t\tframes={14},"
      "\t},"
      "\t[\"move\"]="
      "\t{"
      "\t\tticks=6,"
      "\t\thframes={1,1,1,1},"
      "\t\tframes={12,13,14,15},"
      "\t},"
      "\t[\"run\"]= -- this is a hack because only villagers run"
      "\t{"
      "\t\tticks=7,"
      "\t\thframes={17,18,17,18},"
      "\t\tframes={12,13,14,15},"
      "\t},"
      "\t[\"windup\"]="
      "\t{"
      "\t\tticks=10000,"
      "\t\thframes={17},"
      "\t\tframes={45},"
      "\t},"
      "\t[\"attack\"]="
      "\t{"
      "\t\tticks=10000,"
      "\t\thframes={33},"
      "\t\tframes={46},"
      "\t},"
      "\t[\"fly\"]="
      "\t{"
      "\t\tticks=10000,"
      "\t\thframes={49},"
      "\t\tframes={47},"
      "\t},"
      "}"
      ""
      ""
      "function get_direction_to_turn(cur_angle, desired_angle)"
      "\tlocal angle_delta = desired_angle-cur_angle"
      ""
      "\tlocal turn_result = 0"
      "\tif -.5 < angle_delta and angle_delta <= .5 then"
      "\t\tturn_result = angle_delta"
      "\telseif angle_delta > .5 then"
      "\t\tturn_result = angle_delta - 1"
      "\telseif angle_delta <= -.5 then"
      "\t\tturn_result = angle_delta + 1"
      "\tend"
      ""
      "\tif turn_result < 0 then"
      "\t\treturn 1"
      "\telse"
      "\t\treturn -1"
      "\tend"
      "end"
      ""
      "function get_rebound_angle_speed(angle, speed)"
      "\tlocal dir = -.125"
      "\tif randc() then"
      "\t\tdir = .125"
      "\tend"
      "\treturn (angle+.5+dir)%1, speed * .5"
      "end"
      ""
      "function get_angle_from_input()"
      "\tif p1.recovery_time_rem > 0 then"
      "\t\treturn 0"
      "\tend"
      "\tlocal ml, mr, mu, md, angle = btn(0), btn(1), btn(2), btn(3), -1"
      "\tif ml then"
      "\t\tif md then"
      "\t\t\tangle = .625"
      "\t\telseif mu then"
      "\t\t\tangle = .375"
      "\t\telse"
      "\t\t\tangle = .5"
      "\t\tend"
      "\telseif mr then"
      "\t\tif md then"
      "\t\t\tangle = .875"
      "\t\telseif mu then"
      "\t\t\tangle = .125"
      "\t\telse"
      "\t\t\tangle = 0"
      "\t\tend"
      "\telseif md then"
      "\t\tangle = .75"
      "\telseif mu then"
      "\t\tangle = .25"
      "\tend"
      "\treturn angle"
      "end"
      ""
      "-- reduction : remove col_w, col_h and just have one square col. remove col_off. remove c+o in offset, just do -4 global"
      ""
      "function m_player(setx, sety)"
      ""
      "\tlocal p="
      "\t{"
      "\t\tname = \"\","
      "\t\tpcolor=7,"
      "\t\tscolor=6,"
      "\t\tis_player = true,"
      "\t\tx=setx,"
      "\t\ty=sety,"
      "\t\tangle=0,"
      "\t\tspeed_move=0,"
      "\t\tspeed_move_max=1.25,"
      "\t\tcol_w=6,"
      "\t\tcol_h=6,"
      "\t\tcol_off=0,"
      ""
      "\t\tcuranim=\"move\","
      "\t\tcurframe=1,"
      "\t\tanimtick=0,"
      "\t\tflipx=true,"
      "\t\thead_shift=0,"
      "\t\tbody_shift=0,"
      ""
      "    hp_cur=2,"
      "\t\tis_dead=false,"
      ""
      "    recovery_time_rem = 0,"
      "\t\tready_time = 150,"
      "    invuln_frames = 0,"
      "\t\tis_slashing = false,"
      ""
      ""
      "\t\tinit=function(self)"
      "\t\tend,"
      ""
      "    damage=function(self, source, do_kill)"
      "      if self.invuln_frames > 0 and not do_kill then"
      "        return false"
      "      end"
      ""
      "\t\t\tlocal blood_angle = atan2(self.x - source.x, self.y - source.y)"
      "\t\t\tm_part_bloodsplash(self.x, self.y, blood_angle)"
      "      game_pause(5)"
      "      cam:shake(3, 20)"
      ""
      "\t\t\tg_player_damaged_time, self.invuln_frames = 10, 60"
      ""
      "\t\t\tself.hp_cur -= 1"
      "      if self.hp_cur <= 0 or g_difficulty > 4 or do_kill then"
      "\t\t\t\tself.is_dead, self.head_shift = true, 0"
      "\t\t\t\tsplit_entity(self, (blood_angle+.5)%1)"
      "\t\t\t\tsfx(10)"
      "        level_end_player_died(source.is_static)"
      "      else"
      "\t\t\t\tsfx(frnda(2))"
      "\t\t\tend"
      ""
      "      return true"
      "    end,"
      ""
      ""
      "\t\tslash=function(self)"
      "\t\t\tif not self.is_slashing then"
      ""
      "\t\t\t\tsfx(frnda(3,4))"
      "\t\t\t\ta_anim_set(self, \"windup\")"
      "\t\t\t\tself.slash_has_impacted,"
      "\t\t\t\tself.is_slashing,"
      "\t\t\t\tself.slash_time,"
      "\t\t\t\tself.slash_speed,"
      "\t\t\t\tself.slash_angle,"
      "\t\t\t\tself.speed_move,"
      "\t\t\t\tself.ready_time ="
      "\t\t\t\tfalse,"
      "\t\t\t\ttrue,"
      "\t\t\t\t5,"
      "\t\t\t\t6,"
      "\t\t\t\tself.angle,"
      "\t\t\t\t0,"
      "\t\t\t\t45"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tif self.is_dead then"
      "\t\t\t\treturn"
      "\t\t\tend"
      ""
      "\t\t\tif self.ready_time > 0 then"
      "\t\t\t\tself.ready_time -= 1"
      "\t\t\t\tif self.ready_time == 0 then"
      "\t\t\t\t\tsfx(7)"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\tcheck_for_footsteps(self)"
      ""
      "\t\t\t-- blood drip from damage"
      ""
      "\t\t\tlocal blood_rate = 0"
      "\t\t\tif self.hp_cur < 2 then"
      "\t\t\t\tblood_rate = 2"
      "\t\t\tend"
      "\t\t\tif blood_rate > 0 then"
      "\t\t\t\tif g_ticks % blood_rate == 0 then"
      "\t\t\t\t\tlocal size = 1"
      "\t\t\t\t\tif randc(10) then"
      "\t\t\t\t\t\tsize = 2"
      "\t\t\t\t\tend"
      "\t\t\t\t\tm_part_blood({size, self.x-2, self.y-2, rnd(1), rnd(1), frnda(3,10)})"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\tif self.invuln_frames > 0 then"
      "\t\t\t\tself.invuln_frames -= 1"
      "\t\t\tend"
      ""
      "\t\t\tif self.recovery_time_rem > 0 then"
      "\t\t\t\tself.recovery_time_rem -= 1"
      "\t\t\t\t--a_anim_set(self, \"stand\")"
      "\t\t\t\treturn"
      "\t\t\tend"
      ""
      "\t\t\tif btnp(4) then"
      "\t\t\t\tif self.ready_time == 0 then"
      "\t\t\t\t\tself:slash()"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\tif self.is_slashing then"
      ""
      "\t\t\t\tself.slash_time -= 1"
      "\t\t\t\tm_part_sprite(49, self.x, self.y, 0, 12, 1, 10, self.flipx, false)"
      ""
      "\t\t\t\tself.x += cos(self.slash_angle) * self.slash_speed"
      "\t\t\t\tself.y += sin(self.slash_angle) * self.slash_speed"
      ""
      "\t\t\t\tif constrain_to_screen(self) then"
      "\t\t\t\t\tsfx(23)"
      "\t\t\t\t\tself.slash_angle, self.slash_speed = get_rebound_angle_speed(self.slash_angle, self.slash_speed)"
      ""
      "\t\t\t\t\tm_part_impact(self)"
      "\t\t\t\tend"
      ""
      "\t\t\t\tif self.slash_time == 0 then"
      "\t\t\t\t\tself.is_slashing, self.recovery_time_rem = false, 10"
      "\t\t\t\t\ta_anim_set(self, \"attack\")"
      "\t\t\t\tend"
      "\t\t\telse"
      "\t\t\t\tlocal input_angle = get_angle_from_input()"
      ""
      "\t\t\t\tif input_angle >= 0 then"
      "\t\t\t\t\t--[["
      "\t\t\t\t\tif (input_angle+.5)%1 == self.angle then"
      "\t\t\t\t\t\tself.speed_move = 0"
      "\t\t\t\t\tend"
      "\t\t\t\t\t--]]"
      "\t\t\t\t\tself.angle, self.speed_move  = input_angle, self.speed_move_max"
      "\t\t\t\t\ta_move_angle(self)"
      "\t\t\t\t\ta_anim_set(self, \"move\")"
      "\t\t\t\telse"
      "\t\t\t\t\tself.speed_move = 0"
      "\t\t\t\t\ta_anim_set(self, \"stand\")"
      "\t\t\t\tend"
      ""
      "\t\t\t\tif constrain_to_screen(self) then"
      "\t\t\t\t\tself.speed_move = 0"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\ta_anim_update(self, character_anims)"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tif self.is_dead then"
      "\t\t\t\treturn"
      "\t\t\tend"
      "\t\t\tif self.ready_time == 0 and (self.curanim == \"move\" or self.curanim == \"stand\") then"
      "\t\t\t\tself.body_shift, self.head_shift = 16, 16"
      "\t\t\telse"
      "\t\t\t\tself.body_shift, self.head_shift = 0, 0"
      "\t\t\tend"
      "\t\t\tdraw_character(self)"
      "\t\tend,"
      "\t}"
      ""
      "\tp:init()"
      "\tadd(list_drawstuff, p)"
      "\treturn p"
      "end"
      ""
      "emotion_anims ="
      "{"
      "\t[\"upset\"]="
      "\t{"
      "\t\tticks=7,"
      "\t\tframes={70,71},"
      "\t},"
      "\t[\"angry\"]="
      "\t{"
      "\t\tticks=7,"
      "\t\tframes={72,73,70,74},"
      "\t},"
      "}"
      ""
      "function m_emotion(entity, emotion)"
      "\tlocal e ="
      "\t{"
      "\t\towner=entity,"
      "\t\tcuranim=emotion,"
      "\t\tcurframe=1,"
      "\t\tanimtick=0,"
      "\t\tcolor=g_color_interface,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\ta_anim_update(self, emotion_anims)"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tlocal frame, c_o = emotion_anims[self.curanim].frames[self.curframe], -4"
      "\t\t\tpal(7, self.color)"
      ""
      "\t\t\tspr(frame,"
      "\t\t\t\tself.owner.x+c_o,"
      "\t\t\t\tself.owner.y+c_o-10,"
      "\t\t\t\t1,1, false)"
      "\t\t\tpal()"
      "\t\tend,"
      "\t}"
      "\tentity.emotion = e"
      "end"
      ""
      "--]]"
      ""
      "function get_flipx_from_angle(angle)"
      "\tif angle > .25 and angle <= .75 then"
      "\t\treturn true"
      "\tend"
      "\treturn false"
      "end"
      ""
      "function get_dir_to_player(entity)"
      "\treturn (atan2(entity.x - p1.x, entity.y - p1.y)+.5)%1"
      "end"
      ""
      "function get_yboboffset(self)"
      ""
      "\tif self.curanim == \"move\" then"
      "\t\tif self.curframe % 2 == 0 then"
      "\t\t\treturn -1"
      "\t\tend"
      "\tend"
      "\treturn 0"
      "end"
      ""
      "function m_step(x,y)"
      "\tlocal s ="
      "\t{"
      "\t\tx=x-frnda(4,2),"
      "\t\ty=y,"
      "\t}"
      "\tadd(list_steps, s)"
      "end"
      ""
      "function check_for_footsteps(self)"
      "\t-- do snow stuff"
      "\tif g_season == 3 and not g_level_indoor then"
      "\t\tif randc(50) then"
      "\t\t\tm_step(self.x, self.y)"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function draw_character(self)"
      ""
      "\tlocal yboboffset = get_yboboffset(self)"
      ""
      "\tif not a_set_invuln_flash(self) then"
      "\t\tpal(6,self.scolor)"
      "\t\tpal(7,self.pcolor)"
      "\tend"
      ""
      "\tlocal flip_offset = -1"
      "\tif self.flipx then"
      "\t\tflip_offset = 1"
      "\tend"
      "\tset_outline()"
      "\tspr(character_anims[self.curanim].hframes[self.curframe]+self.head_shift,"
      "\t\tself.x-4,"
      "\t\tself.y-7+yboboffset,"
      "\t\t1,1,"
      "\t\tself.flipx)"
      "\tspr(character_anims[self.curanim].frames[self.curframe]+self.body_shift,"
      "\t\tself.x-4+flip_offset,"
      "\t\tself.y+1+yboboffset,"
      "\t\t1,1,"
      "\t\tself.flipx)"
      "\tpal()"
      "end"
      ""
      "function split_entity(entity, angle)"
      "\tm_bodypart(entity, 42, entity.pcolor, (angle+.300+rnd(.325))%1)"
      "\tm_bodypart(entity, 56+entity.head_shift, entity.scolor, abs(angle-.300-rnd(.325))%1)"
      "end"
      ""
      "function rndbool()"
      "\treturn frnd(2) == 0"
      "end"
      ""
      "function m_bodypart(entity, sprite, replace_color, angle)"
      "\tlocal h="
      "\t{"
      "\t\tx=entity.x,"
      "\t\ty=entity.y,"
      "\t\treplace_color = replace_color,"
      "\t\tangle=angle,"
      "\t\tsprite=sprite,"
      "\t\tspeed_move=.5+rnd(.5),"
      ""
      "\t\tflip_x=rndbool(),"
      ""
      "\t\tdecay_time=frnda(25,25),"
      ""
      "\t\tupdate=function(self)"
      ""
      ""
      "\t\t\t-- if we roll to a stop, start counting down cleanup"
      "\t\t\tif self.speed_move < .1 then"
      "\t\t\t\tself.decay_time -= 1"
      "\t\t\t\tif self.decay_time < 0 then"
      "\t\t\t\t\tdel(list_heads, self)"
      "\t\t\t\t\tdel(list_drawstuff, self)"
      "\t\t\t\t\treturn"
      "\t\t\t\tend"
      "\t\t\telse"
      "\t\t\t\tif g_ticks % 6 == 0 then"
      "\t\t\t\t\tlocal size = 1"
      "\t\t\t\t\tif randc(33) then"
      "\t\t\t\t\t\tsize = 2"
      "\t\t\t\t\tend"
      "\t\t\t\t\t\tm_part_blood({size, self.x, self.y, 0, .25+rnd(.5)})"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\ta_move_angle(self)"
      ""
      "\t\t\tself.speed_move *= .95"
      ""
      "\t\t\tif constrain_to_screen(self) then"
      "\t\t\t\tself.angle, self.speed_move = get_rebound_angle_speed(self.angle, self.speed_move)"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      ""
      "\t\t\tlocal c_o = -4"
      ""
      "\t\t\tset_outline()"
      "\t\t\tpal(6, self.replace_color)"
      ""
      "\t\t\tspr(self.sprite,"
      "\t\t\t\tself.x+c_o,"
      "\t\t\t\tself.y+1+c_o,"
      "\t\t\t\t1,1,"
      "\t\t\t\tself.flip_x)"
      "\t\t\tpal()"
      "\t\tend,"
      "\t}"
      "\tadd(list_heads, h)"
      "\tadd(list_drawstuff, h)"
      "\treturn h"
      "end"
      ""
      "function m_object(x, y, spritelist, is_deadly)"
      "\tlocal o ="
      "\t{"
      "\t\tx=x,"
      "\t\ty=y,"
      "\t\tcol_w=4,"
      "\t\tcol_h=2,"
      "\t\tspritelist=spritelist,"
      "\t\tsprite=1,"
      "\t\tis_static=true,"
      "\t\tis_deadly=is_deadly,"
      ""
      "\t\tupdate=function(self)"
      "\t\tend,"
      ""
      "\t\tdealt_damage=function(self)"
      "\t\t\tself.sprite = 2"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tset_outline()"
      "\t\t\tpal(14, 8)"
      "\t\t\tpal(1, g_color_detail)"
      "\t\t\tspr(self.spritelist[self.sprite], x-4, y-4)"
      "\t\t\tpal()"
      "\t\tend,"
      "\t}"
      "\tadd(list_objects, o)"
      "\tadd(list_drawstuff, o)"
      "\treturn o"
      "end"
      ""
      "function m_food(setx, sety)"
      "\tlocal o = m_object(setx, sety, {99, 99}, false)"
      "\to.col_h, o.col_w, o.eat ="
      "\t6, 6,"
      "\tfunction(self)"
      "\t\tp1.hp_cur = 2"
      "\t\tm_part_sprite(106, self.x, self.y, -.1, g_color_outline, g_color_outline, 15, false, true)"
      "\t\tscore_add(self, 5)"
      "\t\tdel(list_objects, self)"
      "\t\tdel(list_drawstuff, self)"
      "\tend"
      "end"
      ""
      "function add_to_people(entity)"
      ""
      "\tif entity.is_villager then"
      "\t\tadd(list_villagers, entity)"
      "\telse"
      "\t\tadd(list_enemies, entity)"
      "\tend"
      ""
      "\tadd(list_people, entity)"
      "\tadd(list_drawstuff, entity)"
      "end"
      ""
      "function del_from_people(entity)"
      "\tif entity.is_villager then"
      "\t\tdel(list_villagers, entity)"
      "\telseif not entity.is_furniture then"
      "\t\tdel(list_enemies, entity)"
      "\tend"
      "\tdel(list_people, entity)"
      "\tdel(list_drawstuff, entity)"
      "\tif #list_enemies == 0 and g_level_enemies_count == 0 then"
      "\t\tlevel_end_win()"
      "\tend"
      "end"
      ""
      "function a_alert_checkforwindup(entity)"
      "\tif is_level_active() and entity.windup_time_rem == 0 and is_near_objs(entity, p1, entity.alert_distance) then"
      "\t\tentity.windup_time_rem, entity.desired_angle ="
      "\t\tentity.windup_time-entity.emotion_count*3, get_dir_to_player(entity)"
      ""
      "\t\tentity.flipx = get_flipx_from_angle(entity.desired_angle)"
      "\t\ta_anim_set(entity, \"windup\")"
      "\t\treturn true"
      "\telse"
      "\t\treturn false"
      "\tend"
      "end"
      ""
      "function a_deviate(entity, time)"
      "\tif randc(10) then"
      "\t\tentity.deviation_time = frnda(time, time)"
      "\tend"
      "end"
      ""
      "function a_random_turn(entity)"
      "\tlocal angle_adjust = .25"
      "\tif randc() then"
      "\t\tangle_adjust = 0-angle_adjust"
      "\tend"
      ""
      "\tentity.angle_desired = abs(entity.angle_desired+angle_adjust)%1"
      "end"
      ""
      "function m_enemy_villager(setx, sety)"
      "\tlocal e = m_enemy(setx, sety, true)"
      "  e.head_shift, e.body_shift, e.pcolor, e.scolor, e.score ="
      "\t6, 16, 11, 4, -10"
      ""
      "\te.kill_class=function(self, source)"
      "\t\tif source == p1 then"
      "\t\t\tlevel_end_villager_died(true)"
      "\t\telse"
      "\t\t\tlevel_end_villager_died(false)"
      "\t\tend"
      "\t\treturn false"
      "\tend"
      ""
      "\te.touch_class=function(self)"
      "\t\tscore_add(self, 0-self.score-2.5*self.emotion_count)"
      "\t\tdel_from_people(self)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.move=function(self)"
      "\t\ta_deviate(self, 5)"
      "\t\ta_random_turn(self)"
      "\tend"
      ""
      "\te.draw_class=function(self)"
      "\tend"
      ""
      "\treturn e"
      "end"
      ""
      "function nearest_angle(angle)"
      "\tif angle>.825 or angle < .125 then"
      "\t\tangle = 0"
      "\telseif angle < .375 then"
      "\t\tangle = .25"
      "\telseif angle < .625 then"
      "\t\tangle = .5"
      "\telse"
      "\t\tangle = .75"
      "\tend"
      "\treturn angle"
      "end"
      ""
      "function m_arrow(x, y, angle)"
      "\tlocal a ="
      "\t{"
      "\t\tx=x,"
      "\t\ty=y,"
      "\t\tcol_w=4,"
      "\t\tcol_h=4,"
      "\t\tangle=angle,"
      "\t\tspeed_move=3,"
      "\t\tis_static=false,"
      "\t\tis_deadly=true,"
      "\t\tsprite=40,"
      "\t\tflipx=false,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tset_outline()"
      "\t\t\tspr(self.sprite, self.x-4, self.y-4, 1, 1, self.flipx)"
      "\t\t\tpal()"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\ta_move_angle(self)"
      "\t\t\tif constrain_to_screen(self) then"
      "\t\t\t\tself:dealt_damage()"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tdealt_damage=function(self)"
      "\t\t\tdel(list_objects, self)"
      "\t\t\tdel(list_drawstuff, self)"
      "\t\tend,"
      "\t}"
      "\tif angle == .25 or angle ==.75 then"
      "\t\ta.sprite = 41"
      "\tend"
      ""
      "\tadd(list_objects, a)"
      "\tadd(list_drawstuff, a)"
      "end"
      ""
      "function m_enemy_archer(setx, sety)"
      "\tlocal e = m_enemy(setx, sety)"
      "\te.head_shift, e.pcolor, e.scolor, e.alert_distance, e.windup_time, e.time_between_attacks, e.attack_time, e.attack_is_shot = 4, 14, 13, 60, 30, 60, 30, true"
      ""
      "\te.move=function(self)"
      "\t\ta_deviate(self, 10)"
      "\t\tif is_level_active() then"
      "\t\t\tself.angle_desired = get_dir_to_player(self)"
      "\t\tend"
      "\tend"
      ""
      "\te.alert_class=function(self)"
      "\t\tif abs(self.x - p1.x) < 5 or abs(self.y - p1.y) < 5 then"
      "\t\t\tif a_alert_checkforwindup(self) then"
      "\t\t\t\tself.desired_angle = nearest_angle(self.desired_angle)"
      "\t\t\t\tsfx(24)"
      "\t\t\t\treturn true"
      "\t\t\telse"
      "\t\t\t\treturn false"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      ""
      "\te.fire_arrow=function(self)"
      "\t\tsfx(17)"
      "\t\tm_arrow(self.x, self.y, self.desired_angle)"
      "\tend"
      ""
      "\te.draw_class=function(self)"
      "\t\tif self.windup_time_rem > 0 then"
      "\t\t\tset_outline()"
      "\t\t\tlocal arrow_sprite, doflipy = 40, false"
      "\t\t\tif self.desired_angle == .75 then"
      "\t\t\t\tarrow_sprite, doflipy = 41, true"
      "\t\t\telseif self.desired_angle == .25 then"
      "\t\t\t\tarrow_sprite = 41"
      "\t\t\tend"
      "\t\t\tspr(arrow_sprite, self.x-4, self.y-4, 1, 1, self.flipx, doflipy)"
      "\t\t\tpal()"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function m_enemy_wander(setx, sety)"
      "\tlocal e = m_enemy(setx, sety)"
      ""
      "\te.head_shift, e.pcolor = 1, 9"
      ""
      "\te.move=function(self)"
      "\t\ta_deviate(self, 15)"
      "\t\ta_random_turn(self)"
      "\tend"
      ""
      "\te.alert_class=function(self)"
      "\t\treturn a_alert_checkforwindup(self)"
      "\tend"
      ""
      "\treturn e"
      "end"
      ""
      "function m_enemy_bomber(setx, sety)"
      "\tlocal e = m_enemy(setx, sety)"
      ""
      " \te.pcolor, e.scolor, e.head_shift, e.is_fuse_lit, e.is_bomber ="
      "\t8, 4, 3, false, true"
      ""
      "\te.touch_class=function(self)"
      "\t\tself:explode(nil, true)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.update_class=function(self)"
      "\t\tif not self.is_fuse_lit and is_near_objs(self, p1, 25) then"
      "\t\t\tself.is_fuse_lit, self.fuse_timer, self.emotion_count, self.speed_move = true, 500, 1, self.speed_move_orig*2"
      "\t\t\tsfx(35)"
      "\t\tend"
      "\t\tif self.is_fuse_lit then"
      "\t\t\tself.fuse_timer -= 1"
      "\t\t\tif self.fuse_timer <= 0 then"
      "\t\t\t\tself:explode(self, true)"
      "\t\t\tend"
      "\t\t\tif g_ticks % 4 == 0 then"
      "\t\t\t\tm_part_bomb_spark(self.x, self.y-10)"
      "\t\t\tend"
      "\t\tend"
      "\t\treturn true"
      "\tend"
      ""
      "\te.move=function(self)"
      ""
      "\t\ta_deviate(self, 10)"
      "\t\tif is_level_active() then"
      "\t\t\tself.angle_desired = get_dir_to_player(self)"
      "\t\tend"
      "\tend"
      ""
      "\te.explode=function(self, source, no_score)"
      "\t\tif source != nil and source != p1 and not source.is_heavy then"
      "\t\t\tself.score_multiplier = source.score_multiplier + 1"
      "\t\tend"
      ""
      "\t\tif not self.was_counted_for_combo then"
      "\t\t\tself.was_counted_for_combo = true"
      "\t\t\tsfx(frnda(2,33))"
      "\t\t\tm_part_circle(self.x, self.y, 20, 6, 10, 8, 2)"
      ""
      "\t\t\tfor i=-6, 6, 2 do"
      "\t\t\t\tfor j=-6, 6, 2 do"
      "\t\t\t\t\tif randc(75) then"
      "\t\t\t\t\t\tlocal size = frnda(2)"
      ""
      "\t\t\t\t\t\tm_part_blood({size, self.x+i, self.y+j, \tatan2(self.x - (self.x+i), self.y - (self.y+j)), rnd(2)})"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\t\tsplit_entity(self, rnd(1))"
      "\t\t\tcam:shake(3, 10)"
      "\t\t\tgame_pause(2)"
      ""
      "\t\t\tif not no_score then"
      "\t\t\t\tscore_add(self, self.score * self.score_multiplier)"
      "\t\t\tend"
      "\t\tend"
      ""
      "\t\tfor a in all(list_people) do"
      "\t\t\tif a != self and a != source then"
      "\t\t\t\tif not a.was_counted_for_combo and not a.just_spawned and not a.is_armored then"
      "\t\t\t\t\tif is_near_objs(self, a, 20) then"
      "\t\t\t\t\t\tif source != nil and not source.is_heavy then"
      "\t\t\t\t\t\t\tsource.score_multiplier += 1"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\tif not a.is_furniture then"
      "\t\t\t\t\t\t\tif a.is_bomber then"
      "\t\t\t\t\t\t\t\ta:kill(self, no_score)"
      "\t\t\t\t\t\t\telseif not a.is_heavy then"
      "\t\t\t\t\t\t\t\ta:kill(self, true)"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\t-- only for people that didn't explode"
      "\t\t\t\t\t\tif not a.was_counted_for_combo and not a.is_heavy then"
      "\t\t\t\t\t\t\tself.score_multiplier += 1"
      "\t\t\t\t\t\t\ta.was_counted_for_combo = true"
      "\t\t\t\t\t\t\tif not no_score then"
      "\t\t\t\t\t\t\t\tscore_add(a, a.score * self.score_multiplier)"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      ""
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend"
      "\t\tif is_near_objs(self, p1, 20) then"
      "\t\t\tp1:damage(self)"
      "\t\tend"
      ""
      "\t\tdel_from_people(self)"
      ""
      "\tend"
      ""
      "\te.handle_impact_class=function(self, source)"
      "\t\tself:explode(source)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.kill_class=function(self, source, no_score)"
      "\t\tself:explode(source, no_score)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.draw_class=function(self)"
      "\t\tlocal x_off = -5"
      "\t\tif self.flipx then"
      "\t\t\tx_off = -3"
      "\t\tend"
      "\t\tset_outline()"
      "\t\tspr(20, self.x+x_off, self.y-12+get_yboboffset(self), 1, 1, self.flipx)"
      "\t\tpal()"
      "\tend"
      ""
      "\treturn e"
      "end"
      ""
      "function m_enemy_boss(setx, sety)"
      "\tlocal e = m_enemy_seeker(setx, sety)"
      "\te.is_armored, e.head_shift, e.pcolor, e.scolor, e.speed_move_orig = true, 5, 13, 6, .5"
      "\te:init()"
      "end"
      ""
      "function m_enemy_seeker(setx, sety)"
      ""
      "\tlocal e = m_enemy(setx, sety)"
      ""
      "\te.head_shift = 2"
      "\te.move=function(self)"
      "\t\ta_deviate(self, 10)"
      ""
      "\t\tif is_level_active() then"
      "\t\t\tself.angle_desired = get_dir_to_player(self)"
      "\t\tend"
      "\tend"
      ""
      "\te.alert_class=function(self)"
      "\t\treturn a_alert_checkforwindup(self)"
      "\tend"
      ""
      "\treturn e"
      "end"
      ""
      "function m_enemy_furniture(setx, sety, sprite, is_heavy)"
      "\tlocal e = m_enemy(setx, sety)"
      ""
      "\te.update_class=function(self)"
      "\t\tif self.is_flying then"
      "\t\t\tcheck_for_footsteps(self)"
      "\t\t\ta_fly(self)"
      "\t\t  end"
      "\t\treturn false"
      "\tend"
      ""
      "\te.kill_class=function(self)"
      "\t  del_from_people(self)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.touch_class=function(self)"
      "\t\treturn true"
      "\tend"
      ""
      "\te.sprite, e.is_furniture, e.is_heavy = sprite, true, is_heavy or false"
      ""
      "\tdel(list_enemies, e)"
      "\treturn e"
      "end"
      ""
      "function m_enemy(setx, sety, is_villager)"
      "\tlocal e="
      "\t{"
      "\t\tx=setx,"
      "\t\ty=sety,"
      "\t\tpcolor=10,"
      "\t\tscolor=7,"
      "\t\tis_villager = is_villager or false,"
      ""
      "\t\tangle=0,"
      "\t\tangle_desired=0,"
      "\t\talert_distance=15,"
      "\t\tspeed_turn=.01,"
      "\t\tspeed_move_orig=.25+rnd(.1),"
      "\t\tspeed_move=0,"
      ""
      "\t\twindup_time=25,"
      "\t\twindup_time_rem=0,"
      "\t\tdeviation_time=0,"
      ""
      "\t\tcol_w=6,"
      "\t\tcol_h=6,"
      "\t\tcol_off=0,"
      ""
      "\t\tcuranim=\"move\","
      "\t\tcurframe=1,"
      "\t\tanimtick=0,"
      "\t\tflipx=true,"
      ""
      "\t\thead_shift=0,"
      "\t\tbody_shift=0,"
      ""
      "\t\temotion=nil,"
      "\t\temotion_count=0,"
      "\t\temotion_timer=0,"
      ""
      "\t\tfly_speed=0,"
      "\t\tis_flying=false,"
      ""
      "\t\tattack_time=7,"
      "\t\tattack_time_rem=0,"
      "\t\trecovery_time=20,"
      "\t\trecovery_time_rem=0,"
      "\t\ttime_between_attacks=0,"
      "\t\ttime_between_attacks_rem=0,"
      ""
      "\t\tjust_spawned=true,"
      ""
      "    invuln_frames=0,"
      "\t\twander_time=0,"
      "\t\twander_dir=frnd(7),"
      ""
      "    score=1,"
      "    score_multiplier=1,"
      "\t\twas_counted_for_combo=false,"
      ""
      "\t\tinit=function(self)"
      "\t\t\tif is_level_active() then"
      "\t\t\t\tself.invuln_frames, self.speed_move, self.angle = 30, self.speed_move_orig, (atan2(self.x - p1.x, self.y - p1.y)+.5)%1"
      "\t\t\t\tconstrain_to_screen(self)"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tmove=function(self)"
      "\t\tend,"
      ""
      "\t\tattack_target=function(self)"
      "\t\t\tif self.attack_is_shot then"
      "\t\t\t\tself:fire_arrow()"
      "\t\t\t\tattack_reset(self)"
      "\t\t\t\treturn"
      "\t\t\tend"
      ""
      "\t\t\tself.attack_time_rem, self.angle = self.attack_time, self.desired_angle"
      "\t\t\ta_anim_set(self, \"attack\")"
      "\t\t\tsfx(frnda(3,18))"
      "\t\tend,"
      ""
      "\t\thandle_impact_class=function(self)"
      "\t\t\treturn false"
      "\t\tend,"
      ""
      "\t\thandle_impact=function(self, source)"
      "\t\t\tif not self:handle_impact_class(source) then"
      "\t\t\t\tself.is_flying, self.is_flying_impactable, self.windup_time_rem, self.attack_time_rem = true, true, 0, 0"
      "\t\t\t\ta_anim_set(self, \"fly\")"
      "\t\t\t\tself:emotion_add()"
      "\t\t\t\tm_part_impact(self)"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tkill_class=function(self)"
      "\t\t\treturn false"
      "\t\tend,"
      ""
      "\t\tkill=function(self, source, no_score, angle, override)"
      "\t\t\tif not override then"
      "\t\t\t\tif self:kill_class(source, no_score) then"
      "\t\t\t\t\treturn"
      "\t\t\t\tend"
      "\t\t\tend"
      ""
      "\t\t\tlocal source_angle = angle or atan2(source.x - self.x, source.y - self.y)"
      ""
      "\t\t\tm_part_bloodsplash(self.x, self.y, source_angle)"
      ""
      "\t\t\tsplit_entity(self, source_angle)"
      ""
      "\t\t\tif not no_score then"
      "\t\t\t\tscore_add(self, self.score)"
      "\t\t\tend"
      "\t\t\tdel_from_people(self)"
      "\t\tend,"
      ""
      "\t\talert_class=function(self)"
      "\t\t\treturn false"
      "\t\tend,"
      ""
      "\t\ttouch_class=function(self)"
      "\t\t\treturn false"
      "\t\tend,"
      ""
      "\t\tupdate_class=function(self)"
      "\t\t\treturn true"
      "\t\tend,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tif self.invuln_frames > 0 then"
      "\t\t\t\tself.invuln_frames -= 1"
      "\t\t\telse"
      "\t\t\t\tself.just_spawned = false"
      "\t\t\tend"
      "\t\t\tif self.just_spawned then"
      "\t\t\t\treturn"
      "\t\t\tend"
      ""
      "\t\t\tif not self:update_class() then"
      "\t\t\t\tself.just_spawned = false"
      "\t\t\t\treturn"
      "\t\t\tend"
      ""
      "\t\t\tcheck_for_footsteps(self)"
      "\t\t\tif self.is_flying then"
      "\t\t\t\ta_fly(self)"
      "\t\t\telseif self.attack_time_rem > 0 then"
      "\t\t\t\ta_attack(self)"
      ""
      "\t\t\telseif self.windup_time_rem > 0 then"
      "\t\t\t\tself.windup_time_rem -= 1"
      "\t\t\t\tif self.windup_time_rem <= 0 then"
      "\t\t\t\t\tself:attack_target()"
      "\t\t\t\tend"
      "\t\t\telseif self.recovery_time_rem > 0 then"
      "\t\t\t\tself.recovery_time_rem -= 1"
      "\t\t\telseif self.time_between_attacks_rem == 0 and self:alert_class() then"
      "\t\t\telse"
      "\t\t\t\tif self.time_between_attacks_rem  > 0 then"
      "\t\t\t\t\tself.time_between_attacks_rem -= 1"
      "\t\t\t\tend"
      "\t\t\t\tif self.deviation_time > 0 then"
      "\t\t\t\t\tself.deviation_time -= 1"
      "\t\t\t\telse"
      "\t\t\t\t\tself:move()"
      ""
      "\t\t\t\t\tif abs(self.angle - self.angle_desired) < .05 then"
      "\t\t\t\t\t\tself.angle_desired=self.angle"
      "\t\t\t\t\tend"
      ""
      "\t\t\t\t\tif self.angle != self.angle_desired then"
      "\t\t\t\t\t\tself.angle = (self.angle + self.speed_turn*get_direction_to_turn(self.angle_desired, self.angle))"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\t\ta_move_angle(self)"
      "\t\t\t\t\tlocal anim = \"move\""
      "\t\t\t\t\tif self.is_villager and self.emotion_count > 0 then"
      "\t\t\t\t\t\tanim = \"run\""
      "\t\t\t\t\tend"
      "\t\t\t\t\ta_anim_set(self, anim)"
      "\t\t\t\tif constrain_to_screen(self) then"
      "\t\t\t\t\tself.angle = (self.angle+.25)%1"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\t\tself:emotion_update()"
      ""
      "\t\t\ta_anim_update(self, character_anims, self.emotion_count+1)"
      "\t\tend,"
      ""
      "\t\tdraw_class=function(self)"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\tif not self.is_furniture then"
      "\t\t\t\tdraw_character(self)"
      "\t\t\t\tself:draw_class()"
      "\t\t\t\tif self.emotion and not self.is_flying then"
      "\t\t\t\t\tself.emotion:draw()"
      "\t\t\t\tend"
      "\t\t\telse"
      "\t\t\t\tset_outline()"
      "\t\t\t\tspr(self.sprite, self.x-4, self.y-4)"
      "\t\t\t\tpal()"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\temotion_update=function(self)"
      "\t\t\tif self.emotion then"
      "\t\t\t\tself.emotion:update()"
      "\t\t\tend"
      "\t\t\tif self.emotion_timer > 0 then"
      "\t\t\t\tself.emotion_timer -= 1"
      "\t\t\t\tif self.emotion_timer == 0 then"
      "\t\t\t\t\tself.emotion_count -= 1"
      "\t\t\t\t\tself:emotion_set_from_count()"
      "\t\t\t\t\tif self.emotion_count > 0 then"
      "\t\t\t\t\t\tself.emotion_timer = 360"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\temotion_set_from_count=function(self)"
      "\t\t\tif self.emotion_count == 3 then"
      "\t\t\t\tm_emotion(self, \"angry\")"
      "\t\t\telseif self.emotion_count >= 1 then"
      "\t\t\t\tm_emotion(self, \"upset\")"
      "\t\t\telse"
      "\t\t\t\tself.emotion = nil"
      "\t\t\tend"
      "\t\t\tself.speed_move = self.speed_move_orig + .2*self.emotion_count"
      ""
      "\t\tend,"
      ""
      "\t\temotion_add=function(self)"
      "\t\t\tself.emotion_count, self.emotion_timer = min(3, self.emotion_count+1), 360"
      "\t\t\tself:emotion_set_from_count()"
      "\t\tend,"
      "\t}"
      ""
      "\te:init()"
      ""
      "\tadd_to_people(e)"
      "\treturn e"
      "end"
      ""
      "function get_gen_coords()"
      "\tlocal gen_x, gen_y, whichside = frnd(128), frnd(128), frnd(4)"
      "\tif whichside == 0 then"
      "\t\tgen_x = 4"
      "\telseif whichside == 1 then"
      "\t\tgen_x = 124"
      "\telseif whichside == 2 then"
      "\t\tgen_y = 4"
      "\telse"
      "\t\tgen_y = 124"
      "\tend"
      "\treturn gen_x, gen_y"
      "end"
      ""
      "function m_enemy_random()"
      ""
      "\tlocal enemy_type = g_enemy_weights[frnda(#g_enemy_weights)]"
      ""
      "\tif enemy_type == 5 then"
      "\t\tif not g_spawned_boss then"
      "\t\t\tm_enemy_boss(get_gen_coords())"
      "\t\t\tg_spawned_boss = true"
      "\t\telse"
      "\t\t\treturn"
      "\t\tend"
      "\telseif enemy_type == 1 then"
      "\t\tm_enemy_wander(get_gen_coords())"
      "\telseif enemy_type == 2 then"
      "\t\tm_enemy_seeker(get_gen_coords())"
      "\telseif enemy_type == 3 then"
      "\t\tm_enemy_archer(get_gen_coords())"
      "\telse"
      "\t\tm_enemy_bomber(get_gen_coords())"
      "\tend"
      "\t\tg_level_enemies_count -= 1"
      "end"
      ""
      "function set_cam_pos(pos)"
      "\tif pos+8<64 then"
      "\t\tpos+=min(64-(pos+8),4)"
      "\tend"
      "\tif pos-8>64 then"
      "\t\tpos+=min(64-(pos-8),4)"
      "\tend"
      "\treturn pos"
      "end"
      ""
      "function m_cam()"
      "\tcamera()"
      "\tlocal c="
      "\t{"
      "\t\tpos_x = 64,"
      "\t\tpos_y = 64,"
      ""
      "\t\tshake_remaining=0,"
      "\t\tshake_force=0,"
      ""
      "\t\tupdate=function(self)"
      "\t\t\tself.shake_remaining, self.pos_y, self.pos_x = max(0,self.shake_remaining-1), mid(64, set_cam_pos(self.pos_y), 960), mid(64, set_cam_pos(self.pos_x), 960)"
      "\t\t\tcamera(self:cam_pos())"
      "\t\tend,"
      ""
      "\t\tcam_pos=function(self)"
      "\t\t\tlocal shk_x, shk_y, force = 0, 0, self.shake_force"
      ""
      "\t\t\tif self.shake_remaining>0 then"
      "\t\t\t\tshk_x, shk_y = rnd(force)-force/2, rnd(force)-force/2"
      "\t\t\tend"
      "\t\t\treturn self.pos_x-64+shk_x,shk_y"
      "\t\tend,"
      ""
      "\t\tshake=function(self, force, duration)"
      "\t\t\tself.shake_force, self.shake_remaining = force, duration"
      "\t\tend"
      "\t}"
      ""
      "\treturn c"
      "end"
      ""
      "function save_score()"
      "\tif g_score_total >= g_high_scores[g_difficulty][1] then"
      "\t\tg_high_scores[g_difficulty][1], g_high_scores[g_difficulty][2] = g_score_total, g_year"
      "\tend"
      "\tlocal index = 1"
      "\tfor i=1, 8 do"
      "\t\tfor j=1,2 do"
      "\t\t\tdset(index, g_high_scores[i][j])"
      "\t\t\tindex += 1"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function level_end()"
      "\tp1.ready_time, g_game_state, g_transition_time = 300, 6, 150"
      "\tg_score_total += g_score_level"
      "end"
      ""
      "function level_end_win()"
      "\tif p1.hp_cur > 1 then"
      "\t\tscore_add(p1, 25)"
      "\tend"
      "\tg_game_transition_to_state = 7"
      "\tsfx(13)"
      "  level_end()"
      "end"
      ""
      "function level_end_bad()"
      "\tg_game_transition_to_state = 8"
      "\tsfx(12)"
      "\tlevel_end()"
      "\tsave_score()"
      "end"
      ""
      "function level_end_villager_died(killed_by_player)"
      "\tif g_difficulty < 7 then"
      "\t\treturn"
      "\tend"
      "\tg_level_end_reason = \"let a villager die\""
      "\tif killed_by_player then"
      "\t\tg_level_end_reason = \"killed a villager\""
      "\tend"
      "\tlevel_end_bad()"
      "end"
      ""
      "function level_end_player_died(killed_by_obstacle)"
      "  g_level_end_reason = \"slain in combat\""
      "\tif killed_by_obstacle then"
      "\t\tg_level_end_reason = \"stumbled into death\""
      "\tend"
      "\tlevel_end_bad()"
      "end"
      ""
      "function m_splat(x, y, size_base, size_var)"
      "\tlocal s ="
      "\t{"
      "\t\tx=x,"
      "\t\ty=y,"
      "\t\tsize=frnda(size_var, size_base),"
      ""
      "\t\tdraw=function(self, color)"
      "\t\t\tif color == 0 then"
      "\t\t\t\tcircfill(self.x, self.y, self.size+1, color)"
      "\t\t\telse"
      "\t\t\t\tcircfill(self.x, self.y, self.size, color)"
      "\t\t\tend"
      "\t\tend,"
      "\t}"
      "\treturn s"
      "end"
      ""
      "function m_transition_splatter()"
      "\tlocal t ="
      "\t{"
      "\t\tlist_splats={},"
      ""
      "\t\tinit=function(self)"
      "\t\t\tlocal wipe_position = 0"
      "\t\t\twhile wipe_position < 128 do"
      ""
      "\t\t\t\twipe_position += 10"
      ""
      "\t\t\t\tadd(self.list_splats, m_splat(wipe_position+2-rnd(4), 48-frnd(6), 10, 8))"
      "\t\t\t\tadd(self.list_splats, m_splat(wipe_position+2-rnd(4), frnda(6, 80), 10, 8))"
      ""
      "\t\t\t\tif randc() then"
      "\t\t\t\t\tadd(self.list_splats, m_splat(wipe_position+4-rnd(8), 30-frnd(15), 2, 5))"
      "\t\t\t\tend"
      ""
      "\t\t\t\tif randc() then"
      "\t\t\t\t\tadd(self.list_splats, m_splat(wipe_position+4-rnd(8), frnda(15,98), 2, 5))"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend,"
      ""
      "\t\tdraw=function(self)"
      "\t\t\trectfill(0, 41, 128, 87, 0)"
      ""
      "\t\t\tfor s in all(self.list_splats) do"
      "\t\t\t\ts:draw(0)"
      "\t\t\tend"
      "\t\t\trectfill(0, 42, 128, 86, 8)"
      ""
      "\t\t\tfor s in all(self.list_splats) do"
      "\t\t\t\ts:draw(8)"
      "\t\t\tend"
      ""
      "\t\tend,"
      "\t}"
      "\tt:init()"
      "\treturn t"
      "end"
      ""
      "function is_level_active()"
      "\tif g_game_state == 5 or g_game_state == 6 then"
      "\t\treturn true"
      "\tend"
      ""
      "\treturn false"
      "end"
      ""
      "function update_weather()"
      "\t---[["
      "\tif g_weather_part_rate == 0 then"
      "\t\treturn"
      "\tend"
      "\tif g_ticks % g_weather_part_rate == 0 then"
      ""
      "\t\tlocal part_sprite, part_color, double_rate = g_weather_sprite, g_weather_color, 0"
      ""
      "\t\tif g_season == 0 then"
      "\t\t\tdouble_rate = 1"
      "\t\telseif g_season == 3 then"
      "\t\t\tpart_sprite += frnd(2)"
      "\t\t\tif not g_level_night then"
      "\t\t\t\tpart_color += frnd(2)"
      "\t\t\tend"
      "\t\tend"
      ""
      "\t\tfor i=0,double_rate do"
      "\t\t\tlocal p = m_part_sprite(part_sprite, frnd(256)-128, -8, g_weather_fall_rate, part_color, part_color, 300, false, true)"
      "\t\t\tif g_season == 0 then"
      "\t\t\t\tp.dx,\tp.splash_loc = .3+rnd(.1), frnda(128, 16)"
      "\t\t\t\tp.update=function(self)"
      "\t\t\t\t\tif self.y >= self.splash_loc then"
      "\t\t\t\t\t\tfor i=0,1 do"
      "\t\t\t\t\t\t\tlocal s = m_part_sprite(103, self.x, self.y, -rnd(1), 12, 12, 5, false, true)"
      "\t\t\t\t\t\t\ts.ddy, s.dx = .1, rnd(.5)"
      "\t\t\t\t\t\t\tif randc(50) then"
      "\t\t\t\t\t\t\t\ts.dx = -rnd(.5)"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\tdel(list_parts_front, self)"
      "\t\t\t\t\tend"
      "\t\t\t\t\tself:update_base()"
      "\t\t\t\tend"
      "\t\t\telse"
      "\t\t\t\tp.update=function(self)"
      "\t\t\t\t\tif self.y > 128 then"
      "\t\t\t\t\t\tdel(list_parts_front, self)"
      "\t\t\t\t\t\treturn"
      "\t\t\t\t\tend"
      "\t\t\t\t\tif randc(25) then"
      "\t\t\t\t\t\tlocal wshift = g_weather_wind_shift"
      "\t\t\t\t\t\tif randc(50) then"
      "\t\t\t\t\t\t\twshift = -g_weather_wind_shift"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\tself.dx += wshift"
      "\t\t\t\t\tend"
      "\t\t\t\t\tself.dx = mid(-1, self.dx, 1)"
      "\t\t\t\t\tself:update_base()"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "\t--]]"
      "end"
      ""
      "function _update60()"
      "\tg_ticks += 1"
      "\t--[["
      "\tif stat(9) < stat(8) then"
      "\t--\tprinth(\"dropped frame \"..g_ticks)"
      "\tend"
      "--]]"
      "\tcam:update()"
      "\tlocal fu = function(i) i:update() end"
      ""
      "\tif g_game_state == 6 then"
      "\t\tg_transition_time -= 1"
      "\t\tif g_transition_time <= 0 then"
      "\t\t\tcam:shake(3, 20)"
      "\t\t\tg_game_state = g_game_transition_to_state"
      "\t\t\tsfx(9)"
      "\t\tend"
      "\t\tif g_ticks % 2 == 0 then"
      "\t\t\treturn"
      "\t\tend"
      "\tend"
      ""
      "\tif g_game_state == 4 then"
      "\t\tg_transition_time -= 1"
      "\t\tif g_transition_time <= 0 then"
      "\t\t\tg_game_state = 5"
      "\t\tend"
      "\tend"
      ""
      "\tforeach(list_parts_blood, fu)"
      "\tforeach(list_parts_back, fu)"
      "\tforeach(list_parts_front, fu)"
      ""
      "\tif g_game_state > 3 and g_game_state < 9 then"
      "\t\tif game_pause_timer > 0 then"
      "\t\t\tgame_pause_timer -= 1"
      "\t\t\treturn"
      "\t\tend"
      ""
      "\t\tupdate_weather()"
      "\t\tif g_player_damaged_time > 0 then"
      "\t\t\tg_player_damaged_time -= 1"
      "\t\tend"
      "\t\tif g_game_state > 4 then"
      "\t\t\tif g_ticks % 25 == 0 and (#list_enemies + #list_villagers) < g_level_people_screen_max then"
      "\t\t\t\tif randc(85) and g_level_enemies_count > 0 then"
      "\t\t\t\t \tm_enemy_random()"
      "\t\t\t\telse"
      "\t\t\t\t\tif g_level_villagers_count > 0 then"
      "\t\t\t\t\t\tg_level_villagers_count -= 1"
      "\t\t\t\t\t\tm_enemy_villager(get_gen_coords())"
      "\t\t\t\t\telseif g_level_enemies_count > 0 then"
      "\t\t\t\t\t\tm_enemy_random()"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend"
      ""
      "\t\tp1:update()"
      ""
      "\t\tforeach(list_heads, fu)"
      "\t\tfor e in all(list_people) do"
      "\t    e:update()"
      "\t\t\t-- only allow damage and impacts if we're in the game proper (not in transition)"
      "\t\t\tif g_game_state == 5 then"
      "\t\t\t\tif int_cols(p1, e, 2) then"
      "\t\t\t\t\tif p1.is_slashing and not p1.slash_has_impacted then"
      "\t\t\t\t\t\tif e.is_villager or (not e.is_furniture and #list_enemies == 1 and g_level_enemies_count == 0) then"
      "\t\t\t\t\t\t\tm_part_impact(e)"
      "\t\t\t\t\t\t\te:kill(p1, false, p1.slash_angle, not e.is_villager)"
      "\t\t\t\t\t\telse"
      "\t\t\t\t\t\t\tif e.attack_time_rem > 0 then"
      "\t\t\t\t\t\t\t\tif not attempt_deflect_target(e) then"
      "\t\t\t\t\t\t\t\t\tslash_target(e)"
      "\t\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\t\telse"
      "\t\t\t\t\t\t\t\tslash_target(e)"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\tbreak"
      "\t\t\t\t\tend"
      "\t\t\t\t\tif not p1.is_slashing and not e.is_flying and int_cols(p1, e) then"
      "\t\t\t\t\t\tif not e:touch_class() then -- if an enemy a class doesn't handle touch uniquely, do damage when touching"
      "\t\t\t\t\t\t\tif e.attack_time_rem > 0 or g_difficulty > 2 then"
      "\t\t\t\t\t\t\t\tp1:damage(e)"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      "\t\t\t    end"
      "\t\t\t\tend"
      ""
      "\t\t\t\tif e.attack_time_rem > 0 then"
      "\t\t\t\t\tfor v in all(list_villagers) do"
      "\t\t\t\t\t\tif not v.is_flying and int_cols(e, v) then"
      "\t\t\t\t\t\t\tv:kill(e, false, e.angle)"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tif e.is_flying then"
      "\t\t\t\t\tforeach(list_objects, function(o)"
      "\t\t\t\t\t\tif o.is_deadly and o.is_static and not e.is_heavy and not e.is_armored and int_cols(e, o, 2) then"
      "\t\t\t\t\t\t\thandle_impact_death(e, o)"
      "\t\t\t\t\t\t\tsfx(25)"
      "\t\t\t\t\t\t\tif not e.is_furniture then"
      "\t\t\t\t\t\t\t\to:dealt_damage()"
      "\t\t\t\t\t\t\tend"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\tend)"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t  end"
      ""
      "\t\tif g_game_state == 5 then"
      "\t\t\tif is_timed_mode() then"
      "\t\t\t\tg_rushmode_ticks -= 1"
      "\t\t\t\tif g_rushmode_ticks % 60 == 0 and g_rushmode_ticks < 420 then"
      "\t\t\t\t\tsfx(16)"
      "\t\t\t\tend"
      "\t\t\t\tif g_rushmode_ticks < 60 then"
      "\t\t\t\t\tp1:damage(p1, true)"
      "\t\t\t\t\tg_level_end_reason = \"ran out of time\""
      "\t\t\t\t\tlevel_end_bad()"
      "\t\t\t\t\treturn"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\t\tforeach(list_objects, function(o)"
      "\t\t\t\to:update()"
      "\t\t\t\tif int_cols(o, p1) then"
      "\t\t\t\t\tif o.is_deadly then"
      "\t\t\t\t\t\tp1:damage(o)"
      "\t\t\t\t\t\to:dealt_damage()"
      "\t\t\t\t\telse"
      "\t\t\t\t\t\to:eat()"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend)"
      "\t\tend"
      "\tend"
      "\t--[["
      "\tif g_game_state == 5 then"
      "\t\tif btnp(5) then"
      "\t\t\ttransition_level()"
      "\t\tend"
      "\tend"
      "\t--]]"
      "\tif g_game_state > 6 then"
      "\t\tif g_ticks % 5 == 0 then"
      "\t\t\tlocal p = m_part_sprite(86, frnda(118,10), 46+frnd(36), 0, 7, 13, frnda(5,10), false, false)"
      "\t\t\tp.dx = -1"
      "\t\tend"
      "\t\tif btnp(4) then"
      "\t\t\tif g_game_state == 7 then"
      "\t\t\t\ttransition_level()"
      "\t\t\telse"
      "\t\t\t\treset_game()"
      "\t\t\tend"
      "\t\tend"
      "\telseif g_game_state == 0 then"
      "\t\tif btnp(4) then"
      "\t\t\tsfx(0)"
      "\t\t\tsfx(11)"
      "\t\t\tg_game_state = 4"
      "--[["
      "\t\t\tfor i=1,23 do"
      "\t\t\t\ttransition_level()"
      "\t\t\tend"
      "\t\t\t--]]"
      "\t\t\treset_level()"
      "\t\tend"
      "\t\tif btnp(0) then"
      "\t\t\tg_difficulty -= 1"
      "\t\telseif btnp(1) then"
      "\t\t\tg_difficulty += 1"
      "\t\tend"
      "\t\tg_difficulty = wrap(g_difficulty, 1, 8)"
      "\tend"
      "\tif btnp(5) then"
      "\t\tif g_game_state < 4 then"
      "\t\t\tsfx(0)"
      "\t\t\treset_level()"
      "\t\t\tif g_game_state == 1 then"
      "\t\t\t\tm_food(68,68)"
      "\t\t\t\tm_enemy_villager(60, 68)"
      "\t\t\telseif g_game_state == 0 then"
      "\t\t\t\tp1 = m_player(64,39)"
      "\t\t\t\tm_enemy_wander(33, 83)"
      "\t\t\t\tm_enemy_seeker(43, 83)"
      "\t\t\t\tm_enemy_archer(53, 83)"
      "\t\t\t\tm_enemy_bomber(63, 83)"
      "\t\t\t\tm_enemy_boss(73, 83)"
      "\t\t\t\tm_object(83, 83, {160,161}, true)"
      "\t\t\t\tm_object(93, 83, {176,177}, true)"
      ""
      "\t\t\t\tm_enemy_villager(64, 109)"
      "\t\t\tend"
      "\t\t\tg_game_state = wrap(g_game_state+1, 0, 3)"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function level_create()"
      "\tp1 = m_player(64,64)"
      "\treload(0x2000, 0x2000, 0x1000) -- reload original map data"
      ""
      "\tlocal color_choice, block_sel_x, block_sel_y = g_season, frnd(2), 0"
      ""
      "\tif g_year ~= g_year_endgame then"
      "\t\tif g_year ~= 1 then"
      "\t\t\tif randc(25) then"
      "\t\t\t\tg_level_indoor, block_sel_y ="
      "\t\t\t\ttrue, 1"
      "\t\t\tend"
      ""
      "\t\t\tif randc(25) then"
      "\t\t\t\tg_level_night = true"
      "\t\t\tend"
      ""
      "\t\t\tif not g_level_indoor then"
      "\t\t\t\tif randc(25) then"
      "\t\t\t\t\tg_weather_sprite,"
      "\t\t\t\t\tg_weather_color,"
      "\t\t\t\t\tg_weather_part_rate,"
      "\t\t\t\t\tg_weather_wind_shift,"
      "\t\t\t\t\tg_weather_fall_rate ="
      "\t\t\t\t\tg_weather_seasondata[g_season*5+1],"
      "\t\t\t\t\tg_weather_seasondata[g_season*5+2],"
      "\t\t\t\t\tg_weather_seasondata[g_season*5+3],"
      "\t\t\t\t\tg_weather_seasondata[g_season*5+4],"
      "\t\t\t\t\tg_weather_seasondata[g_season*5+5]"
      ""
      "\t\t\t\t\tif g_level_night and g_season ~= 0 then"
      "\t\t\t\t\t\tg_weather_color = 1"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\tend"
      "\t\tend"
      "\telse"
      "\t\tblock_sel_x = 2"
      "\tend"
      ""
      "\tif block_sel_y == 0 then"
      "\t\tg_level_people_screen_max, g_level_screen_buffer = 7+1*g_year, 0"
      "\tend"
      ""
      "\tif g_level_indoor then"
      "\t\tcolor_choice = 6"
      "\tend"
      "\tif g_level_night then"
      "\t\tcolor_choice = 4"
      "\t\tif g_level_indoor then"
      "\t\t\tcolor_choice = 5"
      "\t\tend"
      "\tend"
      ""
      "\tlocal colors_string = \"03,11,05,00,07,02,11,09,10,05,00,07,04,04,04,09,05,00,07,02,10,07,06,05,00,05,06,00,00,01,05,00,07,02,12,00,01,04,00,07,02,07,00,02,09,00,07,01,07\""
      "\t\t--                                       |                    |                    |                    |                    |                    |                    |"
      "\t\t--\t\t\t\t\t\t\t\t\tspring\t\t\t\t\t\t\t summer\t\t\t\t\t\t\t\tfall\t\t\t\t\t\t\t\t winter\t\t\t\t\t\t\t\tnight\t\t\t\t\t\t\t\t indoor dark\t\t\t\t\tindoor light"
      "\t--\t\t\t\t\t\t\t\t\t\tcolor_ground, color_detail, color_wall, color_outline, color_interface, color_blood_burn, color_title_text"
      ""
      "\tlocal cl, offset = split(colors_string), color_choice*7"
      ""
      "\tg_color_ground, g_color_detail, g_color_wall, g_color_outline, g_color_interface, g_color_blood_burn, g_color_title_text ="
      "\tcl[1+offset], cl[2+offset], cl[3+offset], cl[4+offset], cl[5+offset], cl[6+offset], cl[7+offset]"
      ""
      "\tlocal replace_weights, has_placed_food = split(\"65,81,97,160,176,999\"), false"
      "\tfor y=0, 15 do"
      "\t\tfor x=0, 15 do"
      "\t\t\tlocal tile, swapped_tile = mget(x+block_sel_x*16, y+block_sel_y*16), false"
      "\t\t\tif tile == 160 then"
      "\t\t\t\tif randc() or g_year == g_year_endgame then"
      "\t\t\t\t\tlocal coord_x, coord_y, chosen = x*8+4, y*8+4, replace_weights[frnda(#replace_weights)]"
      "\t\t\t\t\t-- start with basic spike, then possible add to get the other type"
      "\t\t\t\t\tif chosen > 998 or g_year == g_year_endgame then"
      "\t\t\t\t\t\tif has_placed_food then"
      "\t\t\t\t\t\t\tdel(replace_weights, 999)"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\thas_placed_food = true"
      "\t\t\t\t\t\tm_food(coord_x, coord_y)"
      "\t\t\t\t\telseif chosen > 97 then"
      "\t\t\t\t\t\tm_object(coord_x, coord_y, {chosen, chosen+1}, true)"
      "\t\t\t\t\telse"
      "\t\t\t\t\t\tif g_level_indoor then"
      "\t\t\t\t\t\t\tchosen -= 1"
      "\t\t\t\t\t\tend"
      "\t\t\t\t\t\tm_enemy_furniture(coord_x, coord_y, chosen, chosen > 81)"
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tswapped_tile = true"
      "\t\t\tend"
      "\t\t\tif swapped_tile then"
      "\t\t\t\tif g_level_indoor then"
      "\t\t\t\t\tmset(x, y, 144)"
      "\t\t\t\telse"
      "\t\t\t\t\tmset(x, y, 0)"
      "\t\t\t\tend"
      "\t\t\telse"
      "\t\t\t\tmset(x, y, tile)"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      "end"
      ""
      "function transition_level()"
      ""
      "\tg_season += 1"
      "\tif g_season > 3 then"
      "\t\tg_season = 0"
      "\t\tg_year += 1"
      ""
      "\t\tif g_year == 7 then"
      "\t\t\tadd(g_enemy_weights, 5)"
      "\t\tend"
      ""
      "\t\tfor i=1, 4 do"
      "\t\t\tif g_year+1 >= i then"
      "\t\t\t\tadd(g_enemy_weights, i)"
      "\t\t\tend"
      "\t\tend"
      "\tend"
      ""
      "\treset_level()"
      "\tif g_year == g_year_endgame then"
      "\t\tg_game_state = 9"
      "\t\tsfx(15)"
      "\t\tp1.y = 108"
      "\t\tm_enemy_villager(36, 24)"
      "\t\tm_enemy_villager(92, 24)"
      "\t\tm_enemy_villager(52, 108)"
      "\t\tm_enemy_villager(76, 108)"
      "\t\tg_score_total += 1000"
      "\t\tg_level_end_reason = \"returned home\""
      "\t\tsave_score()"
      "\telse"
      "\t\tsfx(11)"
      "\t\tg_game_state = 4"
      "\tend"
      "end"
      ""
      "function reset_level()"
      "\tcam=m_cam()"
      "\ttable_clear(list_parts_back)"
      "\ttable_clear(list_parts_front)"
      "\ttable_clear(list_parts_blood)"
      "\ttable_clear(list_heads)"
      "\ttable_clear(list_enemies)"
      "\ttable_clear(list_villagers)"
      "\ttable_clear(list_people)"
      "\ttable_clear(list_drawstuff)"
      "\ttable_clear(list_objects)"
      "\ttable_clear(list_steps)"
      ""
      "\tg_spawned_boss, g_rushmode_ticks,"
      "\tg_ticks, g_transition_to_state, g_transition_time,"
      "\tg_player_damaged_time, g_level_screen_buffer,"
      "\tg_level_villagers_count, g_level_enemies_count, g_level_people_screen_max,"
      "\tg_score_level,"
      "\tgame_pause_timer,"
      "\tg_level_indoor, g_level_night,"
      "\tg_weather_sprite, g_weather_color, g_weather_part_rate, g_weather_wind_shift, g_weather_fall_rate ="
      "\tfalse, 1200+60*g_year,"
      "\t0, 0, 150,"
      "\t0, 16,"
      "\t3+flr(.5*g_year), 7+3*g_year, 4+1*g_year,"
      "\t0,"
      "\t0,"
      "\tfalse, false,"
      "\t0, 0, 0, 0, 0"
      ""
      "\tif g_game_state > 3 then"
      "\t\tlevel_create()"
      "\tend"
      ""
      "\tcls(g_color_ground)"
      "\tpal(1, g_color_detail)"
      "\tpal(2, 0)"
      "\tpal(5, g_color_wall)"
      "\tmap(0,0,0,0,16,16)"
      "\tpal()"
      "\tcopy_screen_to_mem()"
      ""
      "\ttransition_splatter = m_transition_splatter()"
      "end"
      ""
      "function reset_game()"
      "  -- initialized variables, but change during game"
      "\tg_game_state, g_level_end_reason,"
      "\tg_year, g_season,"
      "\tg_score_total,"
      "\tg_level_screen_buffer, g_ticks,"
      "\tg_enemy_weights ="
      "\t0, \"defeated the vandals\","
      "\t1, 0,"
      "\t0,"
      "\t16, 0,"
      "\tsplit(\"1,1,1,2,2,2,2\")"
      ""
      "\treset_level()"
      ""
      "  cam:shake(3, 20)"
      "\tsfx(9)"
      "end"
      ""
      ""
      "function _init()"
      "\tcartdata(\"tmirobot_bunbunsamurai_4\")"
      "\tg_alphabet_sprites,"
      "\tg_season_names,"
      "\tg_weather_seasondata,"
      "\tg_difficulty_strings,"
      "\tg_difficulty_descs,"
      "\tg_year_endgame,"
      "\tg_difficulty ="
      "\tsplit(\"a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,0,1,2,3,4,5,6,7,8,9\", \",\", false),"
      "\tsplit(\"spring,summer,fall,winter,140,142,172,174\"),"
      "\tsplit(\"119,12,1,0,3,121,14,6,.05,.5,123,9,6,.05,.5,121,6,1,.1,1\"),"
      "\tsplit(\"easy,easy,norm,norm,hard,hard,hell,hell\"),"
      "\tsplit(\"enemy strikes deal damage,s,enemy touches deal damage,s,hero dies from a single hit,s,villager death ends the game,s\"),"
      "\t10,"
      "\t3"
      ""
      "\tlocal index = 1"
      "\tg_high_scores = {}"
      "\tfor i=1,8 do"
      "\t\tg_high_scores[i] = {}"
      "\t\tfor j=1,2 do"
      "\t\t\tg_high_scores[i][j] = dget(index)"
      "\t\t\tindex += 1"
      "\t\tend"
      "\tend"
      "\treset_game()"
      "end"
      ""
      "-- arrange all items in a list by their y value, (used for drawing them in layered order on the screen)"
      "function sort_by_y(t) --insertion sort, ascending y"
      "  for n=2,#t do"
      "    local i=n"
      "    while i>1 and t[i].y<t[i-1].y do"
      "      t[i],t[i-1]=t[i-1],t[i]"
      "      i-=1"
      "    end"
      "  end"
      "end"
      ""
      "function is_timed_mode()"
      "\treturn g_difficulty % 2 == 0"
      "end"
      ""
      "function _draw()"
      ""
      "\tif g_game_state > 3 and g_game_state < 10 then"
      "\t\tpaste_screen_from_mem ()"
      ""
      "\t\tfor a in all(list_parts_blood) do"
      "\t\t\tif a.time == a.duration then"
      "\t\t\t\ta:draw()"
      "\t\t\tend"
      "\t\tend"
      ""
      "\t\t-- draw snow steps"
      "\t\tfor a in all (list_steps) do"
      "\t\t\tpal(7, g_color_detail)"
      "\t\t\tspr(87+frnd(2), a.x, a.y)"
      "\t\t\tpal()"
      "\t\t\tdel(list_steps, a)"
      "\t\tend"
      ""
      "\t\tcopy_screen_to_mem()"
      ""
      "\t\tif g_player_damaged_time > 0 then"
      "\t\t\tcls(8)"
      "\t\tend"
      "\t\tif g_game_state == 9 then"
      "\t\t\trectfill(0,40,128,88,12)"
      "\t\tend"
      ""
      "\t\tlocal fd = function(i) i:draw() end"
      ""
      "\t\t-- sort the list of obstacles and actors by their y coordinate so we can then draw them in \"screen order\" for correct overlapping"
      "\t\tsort_by_y(list_drawstuff)"
      "\t\tforeach(list_parts_blood, fd)"
      "\t\tforeach(list_parts_back, fd)"
      "\t\tforeach(list_drawstuff, fd)"
      "\t\tforeach(list_parts_front, fd)"
      ""
      "\t\tif g_game_state == 4 then"
      "\t\t\tlocal season_sprite = g_season_names[5+g_season]"
      "\t\t\tif g_level_night then"
      "\t\t\t\tseason_sprite = 101"
      "\t\t\tend"
      "\t\t\tspr(season_sprite, 56, 26, 2, 2)"
      "\t\t\tspr(season_sprite, 56, 84, 2, 2)"
      "\t\t\tprintsprite(g_season_names[g_season+1], 48, g_color_title_text)"
      "\t\t\tprintsprite(\"year \"..g_year, 70, g_color_title_text)"
      "\t\tend"
      "\t\tif is_level_active() and is_timed_mode() then"
      "\t\t\tprintc_o(\"\"..flr(g_rushmode_ticks/60), 3, 7, g_color_outline)"
      "\t\tend"
      ""
      "\telse"
      "\t\tcls(0)"
      "\tend"
      ""
      "\trect(0,0,127,127,1)"
      ""
      "\tif g_game_state > 0 and g_game_state < 4 then"
      "\t\tif g_game_state == 1 then"
      "\t\t\tprint(\"the \\fchero\\fd, weary of fighting in\\n     endless wars, wanders\\n the countryside, seeking the\\n village he once called home.\\n\\n\\n\\n  on his journey, he finds a\\n   nation overrun by filthy\\n    \\fcbandits\\fd, vulgar \\fcronin\\fd,\\n    and dangerous \\fchazards\\fd.\\n\\n\\n\\nwherever he roams, he protects\\n    the \\fcweak\\fd and \\fchelpless\\fd.\",4,6,13)"
      "\t\telseif g_game_state == 2 then"
      "\t\t\tprint(\"  press \\fc\\142 \\fdto strike enemies,\\n   killing them if they are\\n knocked into another \\fcobject\\fd.\\n\\n build \\fccombo chains\\fd of impacts\\n       for more \\fcprestige\\fd.\\n\\n  save \\fcvillagers\\fd or eat \\fcfood\\fd\\n       to gain \\fcprestige\\fd.\\n\\n\\n\\n    food also heals \\fcwounds\\fd.\\n\\n    finish a season at full\\n    health in order to earn\\n        \\fcbonus prestige\\fd.\",4,6,13)"
      "\t\telseif g_game_state == 3 then"
      "\t\t\tprintc(\"difficulty levels\", 6, 7)"
      "\t\t\t---[["
      "\t\t\tfor i=1,8,2 do"
      "\t\t\t\tlocal i24, scorestring = i*12, \"\""
      "\t\t\t\tprintc(g_difficulty_strings[i], 6+i24, 9)"
      "\t\t\t\tprintc(g_difficulty_descs[i], 14+i24, 12)"
      ""
      "\t\t\t\tfor j=0,1 do"
      "\t\t\t\t\tlocal endyear, yearstr = g_high_scores[i+j][2], \"home\""
      "\t\t\t\t\tif endyear ~= g_year_endgame then"
      "\t\t\t\t\t\tyearstr = \"year \"..endyear"
      "\t\t\t\t\tend"
      "\t\t\t\t\tscorestring = scorestring..\"\"..(g_high_scores[i+j][1]*10)..\" \"..yearstr"
      "\t\t\t\t\tif j == 0 then"
      "\t\t\t\t\t\tscorestring = scorestring..\" - \""
      "\t\t\t\t\tend"
      "\t\t\t\tend"
      "\t\t\t\tprintc(scorestring, 22+i24, 13)"
      "\t\t\tend"
      "\t\t\t--]]"
      "\t\tend"
      "\t\tprintc(\"\\151 next\", 117, 7, 62)"
      "\t\tfor i in all(list_drawstuff) do"
      "\t\t\ti:draw()"
      "\t\tend"
      "\t\treturn"
      "\tend"
      ""
      "\tif g_game_state > 6 then"
      "\t\tif g_game_state < 9 then"
      "\t\t\ttransition_splatter:draw()"
      "\t\tend"
      "\t\tprintc_o(\"year \"..g_year..\" | \"..g_season_names[g_season+1]..\" | \"..g_difficulty_strings[g_difficulty], 54, 9)"
      "\t\tprintc_o(g_level_end_reason, 46, 10)"
      "\t \tprintc_o(\"prestige: \"..(g_score_total*10)..\"\", 62, 9)"
      "\t\tif g_score_total >= g_high_scores[g_difficulty][1] then"
      "\t\t\tprintc_o(\"(new record)\", 70, 10)"
      "\t\tend"
      "\t\tprintc_o(\"press \\142 to continue\", 78, 7, 2, 62)"
      "\telseif g_game_state == 0 then"
      "\t\ttransition_splatter:draw()"
      "\t\tprintsprite(\"bun bun\", 44, 7)"
      "\t\tprintc(\"s a m u r a i\", 54, 10)"
      "\t\tprintc(\"v1.3a\", 61, 2)"
      "\t\tline(10, 70, 118, 70, 2)"
      "\t\tprintc_o(\"\\142 play | \\139 \"..g_difficulty_strings[g_difficulty]..\" \\145 | \\151 info\", 76, 7, 2, 56)"
      "\t\tif is_timed_mode() then"
      "\t\t\tprintc_o(\"(rush mode)\", 84, 7)"
      "\t\tend"
      "\tend"
      "end")
    (p8-section gfx
      "00000000000000000000000000000000000000000000000000200200000000000000000000000000000000000000000026677772266777722667777226677772"
      "00000000002020000000000000000000000000000220220002822820000000000000000000000000000000000000000002272720022277200227227202222272"
      "00700700024242000020200000000000022022002dd2dd20028dd820002020000000000000000000000000000000000000020200000022000002002000000020"
      "00077000024242000242420002222200244244202dd2dd2002dddd20026262000000000000000000000000000000000000000000000000000000000000000000"
      "0007700028888820299999202aaaaa20288888202eeeee20021a1ad2026262000000000000000000000000000000000000000000000000000000000000000000"
      "00700700024c4c2002484820025c5c20024a4a2002dadad202ddddd2026666200000000000000000000000000000000000000000000000000000000000000000"
      "00000000027777200299992002aa99200288844202eeedd202dddd20026b6b200000000000000000000000000000000000000000000000000000000000000000"
      "000000002266720022669200226652002288822022eee2200266dd20026666200000000000000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000200000000000000222220000000000000000000000000000000000000000000277772002777720027777200277772"
      "00000000002222200022222000222220002620000220220002666662000000000000000000000000000000000000000000272720000277200027227200022272"
      "00000000026666620266666202666662000272002dd2dd20028dd8d2002020000020200000000000000000000000000000020200000022000002002000000020"
      "0000000002427272024292920222a2a2002555202dd2dd2002dddd20026262000262620000000000000000000000000000000000000000000000000000000000"
      "0000000028888820299999202aaaaa20025555522eeeee20021a1ad2026262000262620000000000000000000000000000000000000000000000000000000000"
      "00000000024c4c2002484820025c5c200255555202dadad202ddddd202666620026b6b2000000000000000000000000000000000000000000000000000000000"
      "00000000027777200299992002aa99200255555202eeedd202dddd20266b6b620266162000000000000000000000000000000000000000000000000000000000"
      "00000000027772200299920002aaa2000025552022eee22002dddd20026616202666166200000000000000000000000000000000000000000000000000000000"
      "00000000000000000000000000000000000000000000000000200200000000000000000000002000000000000000000000000000002777720277666202776672"
      "00000000002020000000000000000000000000000220220002822820000000000000000000027200002222000000000000000000027222722722272000227220"
      "00000000024242000020200000000000000000002dd2dd20028dd820000000000200000000027200026686200000000000000000002000200200020000002000"
      "00000000024242000242420002222200000000002dd2dd2002dddd20000000002822222000027200002668200000000000000000000000000000000000000000"
      "0000000028888820299999202aaaaa20000000002eeeee20021a1ad2000000000277777200027200002688200000000000000000000000000000000000000000"
      "00000000024c4c2002484820025c5c200000000002dadad202ddddd2000000002822222000027200026668200000000000000000000000000000000000000000"
      "00000000027777200299992002aa99200000000002eeedd202dddd20000000000200000000282820002222000000000000000000000000000000000000000000"
      "00000000027772200299922002aaa2200000000022eee22002dddd20000000000000000000020200000000000000000000000000000000000000000000000000"
      "0000000000ddddd00000000000000000000000000000000000200200000000000020200000000000000000000000000002202200002002000020200002777772"
      "0000000000007070000000000000000000000000022022000282282000000000024242000020200000000000022022002dd2dd20028228200262620000272220"
      "00000000077777000020200000000000000000002dd2dd20028dd82000202000024242000242420002222200244244202dd2dd20028dd8200262620000020000"
      "00000000007a7a000242420002222200000000002dd2dd2002dddd200262620028888820299999202aaaaa20288888202eeeee2002dddd200266662000000000"
      "0000000000777700299999202aaaaa20000000002eeeee20021a1ad202626200024c4c2002484820025c5c20024a4a2002dadad2021a1ad2026b6b2000000000"
      "000000000077700002484820025c5c200000000002dadad202ddddd2026b6b20027777200299992002aa99200288844202eeedd202ddddd20266162000000000"
      "00000000077777000299992002aa99200000000002eeedd202dddd20026616200022220000222200002222000022222000222220002222200022220000000000"
      "00000000000007000299966202aaa6620000000022eee22002ddd662266616620000000000000000000000000000000000000000000000000000000000000000"
      "00022000002222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00244200024444200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "02444420029444420000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000000000000"
      "02544520294444420000000000000000000000000000000000070000000700000070700000777000007770000000000000000000000000222000000000000000"
      "02455420244444420000000000000000000000000000000000070000000700000777770007007000077777000000000000000000000002555200000000000000"
      "02422420254444520000000000000000000000000000000000070000000000000070700007077000070707000000000000000000000002555200000000000000"
      "02422420255555520000000000000000000000000000000000000000000700000777770007000000077777000000000000000000000002555200000000000000"
      "00200200022222200000000000000000000000000000000000070000000000000070700000777000007070000000000000000000000002555200000000000000"
      "00022000000000000000200000002000000000000000000000000000000000000000000000000000000000000000000000000000000025545520000000000000"
      "002cc200022222200022420000224200000000000000000000000000000000000000000000000000000000000000000000000000000255444552000000000000"
      "02c22c202444444202944920023bb320000000000000000000000000000000000007700000000000000000000000000000000000002554444455200000000000"
      "2cdccdc2255a55522949949223b33b32000000000000000007770070000700000007700000000000000000000000000000000000025544444445520000000000"
      "2ccddcc2244a44422949949223b33b32000000000000000000000000000000000000000000000000000000000000000000000000255444444444552000000000"
      "2dccccd2244444422949949223b33b32000000000000000000000000000000000000000000000000000000000000000000000002554444444444455200000000"
      "02dddd202444444202944920023bb320000000000000000000000000000000000000000000000000000000000000000000000025555555555555555520000000"
      "00222200022222200022220000222200000000000000000000000000000000000000000000000000000000000000000000002255444444444444444552200000"
      "0000000000222200022222200000200000000000000007aaaaa00000000000000000000000770700007707000000000000225555555555555555555555522000"
      "0222222002dddd202fefefe200224200000000000007aaaaaaaaa000000000000000000007887870078878700000000002555555555555555555555555555200"
      "2dddddd2026dddd22ffffff2023b3b2000000000007aaaa9aaaaaa00000000000007000078e8888778e888870000000000222252222222222222222252222000"
      "255a555226ddddd22333333223b3b3b20000000007aaaa999aaaaaa0000000000076700078e8888778e888870000000000000252222222222222222252000000"
      "2ddaddd22dddddd22333333223b3b3b20000000007aaaaa9aa99aaa0000700000007000078888887788888870000000000000252555555555555555252000000"
      "2dddddd225dddd522333333223b3b3b2000000007aaaaaaaa9999aaa000000000000000007888870078888700000000000000252599599959995995252000000"
      "2dddddd22555555202222220023b3b20000000007aaaaaaaa9999aaa000000000000000000788700007887000000000000000252599599959995995252000000"
      "02222220022222200000000000222200000000007aa9aaaaaa99aaaa000000000000000000077000000770000000000000000252599599959995995252000000"
      "00000000002222000000000002222220000000007a999aaaaaaaaaaa000000000000000000000000000000000000000000002252599599959995995252200000"
      "0222222002888820000000002fefefe2000000007aa9aaaaaaaaaaaa000000000000000000000000000000000000000000025555555555555555555555520000"
      "2888d8820268dd82000000002ffffff2000000007aaaaaaaaaaaaaaa000000000007000000070000000000000000700000022222222222222222222222220000"
      "255a585226d8ddd200000000277777720000000007aaaaaaaaaaaaa0000700000071700000777000000000000007700000000000000000000000000000000000"
      "28daddd22dddd8d200000000233333320000000007aaaaaa99aaaaa0000700000007000000070000000700000007000000000000000000000000000000000000"
      "2dddd8d225dddd52000000002333333200000000007aaaaa99aaaa00000000000000000000000000000000000000000000000000000000000000000000000000"
      "2dddddd2255555520000000002222220000000000007aaaaaaaaa000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0222222002222220000000000000000000000000000007aaaaa00000000000000000000000000000000000000000000000000000000000000000000000000000"
      "5555555555050505555555550777777007777770007777700777770007777770077777700777777007700770077777700000000eee0000000000a00aa00a0000"
      "555555555050505550505050077777700777777007777770077007700777777007777770077777700770077007777770000000eeeee000000000aaaaaaaa0000"
      "55555555550505050505050507700770077007700770000007700770077000000770000007700000077007700007700000000eeeeeee00000a0aaaaaaaaaa0a0"
      "55555555505050555050505007777770077777000770000007700770077777000777770007707770077777700007700000088eeeeeee880000aaaaaaaaaaaa00"
      "555555555505050505050505077007700777777007700000077007700770000007700000077000700770077000077000000888eeeee8880000aaaa9999aaaa00"
      "55555555505050555050505007700770077007700770000007700770077000000770000007777770077007700007700000ee88e222e88ee0aaaaa999999aaaaa"
      "5555555555050505050505050770077007777770077777700770077007777770077000000777777007700770077777700eeeee82128eeeee0aaa99999999aaa0"
      "5555555550505055555555550770077007777770007777700777770007777770077000000777777007700770077777700eeeee22122eeeeeaaaa99999999aaaa"
      "0010000000000000000000000777777007700770077000000777777707777770077777700777777007777770077777700eeeee22122eeeeeaaaa99999999aaaa"
      "11111111000000000000000007777770077007700770000007777777077777700777777007777770077777700777777000eeee82128eeee00aaa99999999aaa0"
      "000001000000000000000000000770000777777007700000077070770770077007700770077000700770077007700770000e88e222e88e00aaaaa999999aaaaa"
      "111111110000010000000000000770000777700007700000077070770770077007700770077777700770077007777770000888eeeee8880000aaaa9999aaaa00"
      "00100000001010000010000000077000077777700770000007707077077007700770077007700000077007700777770000088eeeeeee880000aaaaaaaaaaaa00"
      "111111110010101000101000077770000770077007700000077070770770077007777770077000000777777007707770000000eeeee000000a0aaaaaaaaaa0a0"
      "0000010000000000000000000777700007700770077777700770707707700770077777700770000007777707077007700000000eee0000000000aaaaaaaa0000"
      "11111111000000000000000007777000077007700777777007700077077007700777777007700000007777770770077000000000000000000000a00aa00a0000"
      "00000000000000000010000007777770077777700770077007700770077000770770077007700770077777700777777000000000000040000000000c00000000"
      "0000000000000000111dd11107777770077777700770077007700770077070770770077007700770077777700777777000000000000440000000000c00000000"
      "000020000000200000d00d000770000000077000077007700770077007707077007777000770077000000770077007700000000044494000000000ccc0000000"
      "002272200022e2201d5dd5d10777777000077000077007700770077007707077000770000777777000007770077007700000004499994000000c000c000c0000"
      "0272627202e2e2e20dd55dd007777770000770000770077007700770077070770077770000777700000777000770077000000499999940000000cc0c0cc00000"
      "02626262026262621dddddd100000770000770000770077007700770077070770770077000077000007770000770077000004999999940000000ccccccc00000"
      "012121210121212100dddd00077777700007700007777770007777000770707707700770000770000777777007777770000049999999400000c00c0c0c000c00"
      "0000000000000000111111110777777000077000077777700007700007777777077007700007700007777770077777700004999949994000cccccccccccccccc"
      "000222000002220000000000007770000777777007777770077007700777777007700000077777700777777007777770004999949999400000c00c0c0c000c00"
      "00266620002e66200000000007777000077777700777777007700770077777700770000007777770077777700777777000499994999940000000ccccccc00000"
      "0026662000266e200000000007777000000007700000077007700770077000000770000000000770077007700770077000499949999400000000cc0c0cc00000"
      "0276767202e676e2000000000007700007777770007777700777777007777770077777700000077007777770077777700049949999940000000c000c000c0000"
      "0026662000266e20000000000007700007777770007777700777777007777770077777700000077007700770077777700049499999400000000000ccc0000000"
      "0276767202767ee20000000000077000077000000000077000000770000007700770077000000770077007700000077000049999440000000000000c00000000"
      "00266620002666200000000007777770077777700777777000000770077777700777777000000770077777700000077000044444000000000000000c00000000"
      "01211121012111210000000007777770077777700777777000000770077777700777777000000770077777700000077000000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333000333333333333333333333333333330003333333333333333333333333333300033333333333333300000000000000222000000000000000"
      "33333333333330555033333333333333333333333333305550333333333333333333333333333055503333333333333300000000000002555200000000000000"
      "33333333333330555033333333333333333333333333305550333333333333333333333333333055503333333333333300000000000002555200000000000000"
      "33333333333330555033333333333333333333333333305550333333333333333333333333333055503333333333333300000000000002555200000000000000"
      "33333333333330555033333333333333333333333333305550333333333333333333333333333055503333333333333300000000000002555200000000000000"
      "33333333333305545503333333333333333333333333055455033333333333333333333333330554550333333333333300000000000025545520000000000000"
      "33333333333055444550333333333333333333333330554445503333333333333333333333305544455033333333333300000000000255444552000000000000"
      "33333333330554444455033333333333333333333305544444550333333333333333333333055444445503333333333300000000002554444455200000000000"
      "33333333305544444445503333333333333330000000000000000000003333333333333330554444444550333333333300000000025544444445520000000000"
      "33333333055444444444550333333333333305555555555555555555550333333333333305544444444455033333333300000000255444444444552000000000"
      "33333330554444444444455033333333333330000000000000000000003333333333333055444444444445503333333300000002554444444444455200000000"
      "33333305555555555555555503333333333333055555555555555555033333333333330555555555555555550333333300000025555555555555555520000000"
      "33330055444444444444444550033333333330554444444444444445503333333333305544444444444444455033333300002255444444444444444552200000"
      "33005555555555555555555555500333330000000000000000000000000003333300000000000000000000000000033300225555555555555555555555522000"
      "30555555555555555555555555555033305555555555555555555555555550333055555555555555555555555555503302555555555555555555555555555200"
      "33000050000000000000000050000333330000500000000000000000500003333300005000000000000000005000033300222252222222222222222252222000"
      "33333050000000000000000050333333333330500000000000000000503333333333305000000000000000005033333300000252222222222222222252000000"
      "33333050555555555555555050333333333330505555555555555550503333333333305055555555555555505033333300000252555555555555555252000000"
      "33333050599599959995995050333333333330505995999599959950503333333333305059959995999599505033333300000252599599959995995252000000"
      "33333050599599959995995050333333333330505995999599959950503333333333305059959995999599505033333300000252599599959995995252000000"
      "33333050599599959995995050333333333330505995999599959950503333333333305059959995999599505033333300000252599599959995995252000000"
      "33330050599599959995995050033333333300505995999599959950500333333333005059959995999599505003333300002252599599959995995252200000"
      "33305555555555555555555555503333333055555555555555555555555033333330555555555555555555555550333300025555555555555555555555520000"
      "33300000000000000000000000003333333000000000000000000000000033333330000000000000000000000000333300022222222222222222222222220000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000"
      "33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333300000000000000000000000000000000")
    (p8-section label
      "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000088800000000000000000888000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "10000000000888880000000000000008888800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "10000000008888888000000000000088888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008"
      "10000000008888888000000000000088888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088"
      "10000000008888888000000000000088888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088"
      "10000000000888880000000000000008888800000000000000000000088800000000000000000000000000000000000000000000000000000000000000000088"
      "10000000000088800000000000000000888000000000000000000008888888000000000000000000000000000000000000000000000000000000000000000088"
      "10000000000000000000000000000000000000000000000000000008888888000000000000000000000000000000000000000000000000000000000000000088"
      "10000000000000000000000000000000000000000000000000000088888888800000000000000000000000000000000000000000000000000000000000000008"
      "10000000000000000000000000000000000000000000000000000088888888800000000000000000000000000000000000000000000000000000000000000000"
      "10000000000000000000000000000000000000000000000000000088888888800000000000000000000000000000000000000000000000000000000000000000"
      "10000000000000000000000000000000000000000000000000000008888888000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000008888888000000000000000000008888888000000000000000000000000000088800000000000000000000000000000000001"
      "10000000000000000000000008888888888888000000000000000008888888880000000000000000000000000888880000000000000000000000000000000001"
      "10000000000000000000000888888888888888880000000000000888888888888800000000000000000000000888880088888888800000000000000000000001"
      "10000000000000000000008888888888888888888000000000088888888888888888000000000000000000000888888888888888888000000000000000000001"
      "10000008888888000000888888888888888888888880000008888888888888888888880000000000000000000088888888888888888880000000000000000001"
      "10008888888888888008888888888888888888888888000088888888888888888888888880000888888800000088888888888888888888800000000000000000"
      "10888888888888888888888888888888888888888888000888888888888888888888888888888888888888088888888888888888888888880000000000000888"
      "08888888888888888888888888888888888888888888808888888888888888888888888888888888888888888888888888888888888888888000000000888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888800000088888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777778877887788777777888888888877777788778877887777778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777778877887788777777888888888877777788778877887777778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887788778877887788778877888888888877887788778877887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777788877887788778877888888888877777888778877887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777778877887788778877888888888877777788778877887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887788778877887788778877888888888877887788778877887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777778877777788778877888888888877777788777777887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888887777778877777788778877888888888877777788777777887788778888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "888888888888888888888888888888888888888aa88888aaa88888aaa88888a8a88888aaa88888aaa88888aaa888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888a8888888a8a88888aaa88888a8a88888a8a88888a8a888888a8888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888aaa88888aaa88888a8a88888a8a88888aa888888aaa888888a8888888888888888888888888888888888888888"
      "8888888888888888888888888888888888888888a88888a8a88888a8a88888a8a88888a8a88888a8a888888a8888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888aa888888a8a88888a8a888888aa88888a8a88888a8a88888aaa888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888828282288888822282228888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888828288288888888282828888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888828288288888882282228888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888822288288888888282828888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888882882228828822282828888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888882222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88882222222888822222228222222222888822288888222222288882222822222222222288882222222888882228888822222228888222222222222222228888"
      "88822777772288827772728277727272888827288882277777228882772227727772777288822777772288882728888227777722888277727722777227728888"
      "88827722277288827272728272727272888827288882777227728882727272727272777288827722777288882728888277272772888227227272722272728888"
      "88827727277288827772728277727772888827288882772227728882727272727722727288827722277288882728888277727772888827227272772272728888"
      "88827722277288827222722272722272888827288882777227728882727272727272727288827722777288882728888277272772888227227272722272728888"
      "88822777772288827282777272727772888827288882277777228882727277227272727288822777772288882728888227777722888277727272728277228888"
      "88882222222888822282222222222222888822288888222222288882222222222222222288882222222888882228888822222228888222222222228222288888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888888888888888888880008888888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888880000088888880000000000888888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888800000000000000000000000088888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888888000000000000000000000000000888888888888888888888888888888888"
      "88888888888888888888888888888888888888888888888888888888888888888880000000000000000000000000000000888888888888888888888888888888"
      "08888888888888888888888888888888888888800888888888888888888888888000000000000000000000000000000000000000000888888888888888888888"
      "00888888888888888888888888888888888880000088888888888888888888000000000000000000000000000000000000000000000000088888888888888888"
      "10008888888888888888888880888888888800000000088888880000000000000000000000000008888800000000000000000000000000008888888888888888"
      "10000008888888000000888880000088888880000000000000000000000000000008888800000088888880000000000000000000000000000088888888888888"
      "10000000000000000000888880000088888880000000000000000000000000000088888880000888888888000000000000000888000000000000088888880888"
      "10000000000000000000088800000088888880000000000000000000000000000888888888008888888888800000000000008888800000000000000888000888"
      "10000000000000000000000000000008888800000000000000000000000000008888888888808888888888800000000000008888800000000000088888888888"
      "10000000000000000000000000000000888000000000000000000000000000088888888888888888888888800000000000008888800000000000088888888888"
      "10000000000000000000000000000000000000000000000000000000000000088888888888888888888888800000000000000888000000000000888888888888"
      "10000000000000000000000000000000000000000000000000000000000000088888888888888888888888800000000000000000000000000000888888888888"
      "10000000000000000000000000000000000000000000000000000000000000088888888888880888888888000000000000000000000000000000888888888888"
      "10000000000000000000000000000000000000000000000000000000000000088888888888880088888880000000888000000000000000000000088888880008"
      "10000000000000000000000000000000000000000000000000000000000000008888888888800008888800000008888800000000000000000000088888880000"
      "10000000000000000000000000000000000000000000000000000000000000000888888888000000000000000008888800000000000000000000000888000001"
      "10000000000000000000000000000000000000000000000000000000000000000088888880000000000000000008888800000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000008888800000000000000000000888000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001"
      "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"
      "")
    (p8-section gff
      "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000001d0100380000000000000000000000ffffffffff0000000000000000000000ffffffffff0000000000000000000000ffffffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section map
      "00000000000000000000009100000000000000000000000000000092000000000000000000000000000000000000004c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00a0000000000000000000000000a00000a0000000000000000000000000a000000000000000004d4e000092000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000920000000000000000000000000000009100000000000000000000000000000000005c5d5e5f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000a0009200006c6d6e6f00000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000a0000000000000a000920000000000000000000000000000009100000000000000007c7d7e7f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000910000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000009200000000000000a0000000000000000000009200000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00a0000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000000000000000009200000000000000000000000000000000000000000000000000920000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000000000000009200000000000000000000000000000000000000000092000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000a0000000000000a0000000000000000000000000000000000000000000924c4d4e4f000000004c4d4e4f91000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000910000000000000000000000000000009100000000000000000000000000005c5d5e5f000000005c5d5e5f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000910000000000000000000000000000009100000000006c6d6e6f000000006c6d6e6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00a00000000000a0000000000000a00000a00000000000a0000000000000a00000007c7d7e7f000000007c7d7e7f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000920000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8080808080808080808080808080808080808080808080808080808080808080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8080828282828282828282828282808080808282828282828282828282828080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081a090909090909090909090a0818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090a090909090a0909090818080819090a0909090a0909090a0908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090a090909090a0909090818080819090a0909090a0909090a0908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081909090909090909090909090818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8081a090909090909090909090a0818080819090909090909090909090908180000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8080828282828282828282828282808080808282828282828282828282828080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "8080808080808080808080808080808080808080808080808080808080808080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section sfx
      "0101000008550085501d5501d55000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500"
      "00000000332502815015250201501a2501a15015250111500a2500215004250031500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000342502b1501f15014250252501825013250121500e2500625007150072500925000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010400002765027250190502b6502a65024250180502365020450150501d6501a15019150120501765015650131500c0500f6500e2500c0500b6500a1500b0500965007250040500215013450094500265003650"
      "000000002263024630276302b63032630376303b6301013014130181301d13021130251302a1302e1303410038100000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002363026630296302d6303163036630386301e1302113025130271302a1303013033130000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "01000000226302363026630296302d63032630386301a1301f13022130271302d1302f13000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000001d550215502455025550215501b55016550125500d55007550085500b550145501f550255501b50000500005000050000500005000050000500005000050000500005000050000500005000050000500"
      "000100003d150340501c0500b0501205017050170503f7002d1002b0702c17033170381703c1703f1703f07027700287002a7002b700007000070000700007000070000700007000070000700007000070000700"
      "000100000d6500e650106500d1501365015150171501b1501e65021150241502a650116501165010150116501a6501165011650166500e1500f150116501a650116500f150151500060000600006000060000600"
      "010200002f6702e670106701c57023550275502b5102e51031550305502f5502c55029550215501a550185501a55022000290002b0002e0003300037000000000200002000020000200002000020000200002000"
      "3f1600000f335123351433516335193351b335123350f3351e3351b3350f265002000f26500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "3f1600001b335193351633514335123350f3350d3350f335123350f3350f265000050f26500005000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "3e1600001b335193351633514335123350f3350d3350f335163350f3350f265033050f26500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "3e1600000f3150f31512315123150f3150f3150d3150d3150f3150f315123151231514315143150e3150e3150f3150f31512315123150f3150f3150d3150d3150f3150f31514315143150d3150d3150231502315"
      "3e1400001f2211f2211f2211f221222212222122221222211f2211f22122221222211b2211b2211b2211b221162211622116221162211b2211b2211b2211b2211b2211b2211b2211b2211b2211b2211b2211b221"
      "000600001b0501b050010000100001000020000100001000020000400005000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "680200002f650180502f65021050210501e0501d050170500f0500a05008050060500605003050020500205002000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000001b1201c1201f1202012024120241202612028120281200010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100"
      "000000001312016120191201c1201d120211202212025120271200010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100001000010000100"
      "00000000131201512017120191201d1201f1202312026120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002c6502b65024650206501d6501965018650186500f3501035012350143001630000600346003460033600336003260032600326000060000600006000060000600006000060000600006000060000600"
      "000000002965024650216501d6501a6501d6501b65019650186501760016600146001260000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "00000000105700d5700c5700a5700957008570085700a5700d5700f57000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000d05111050170501c0501f0502305006500085010b5000e5000e500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500005000050000500"
      "000100000705007050090500a05006350053501545017450167501675019750000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002865026650236501f6501b65016650146500735009350093500c3500d3500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002965026650236501d6501b650186501665010350113501135015350173500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002765024650216501e6501b65018650166501a3501a3501b3501d3501f3500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002765024650216501f6501e6501b6501965020350203502235024350273500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002565022650206501c6501a6501965018650233502435026350283502b3500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0000000027650246501f6501c6501a65019650176502a3502c3502f35030350333500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000002f650266501e6501b65017650156501b3500c3500a3500a3500a3500a3502d35009350093500040001400014000000000000000000000000000000000000000000000000000000000000000000000000"
      "00030000166501965007250286502865025650062501a6501b6501a650072501b6501c6500b650056500165008600026000160000600006000060000600006000060000600006000060000600006000060000600"
      "000300002d6502d650072501765015650156500c250216501f6501f65007250226501d650136500d6500165008600026000160000600006000060000600006000060000600006000060000600006000060000600"
      "000200002a650170502a6500d6500d6500f6501165013650116500e6500b6500c6500c6500d6500e6500f6500c6500b6500c6500c6500a6500765006650056500465003650026500165001650016500165001650"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section music
      "02 0e404040"
      "00 0e000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      "00 00000000"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a0a6c6973745f656e656d696573203d207b7d0a6c6973745f76696c6c6167657273203d207b7d0a6c6973745f70656f706c65203d207b7d0a6c6973745f647261777374756666203d207b7d0a6c6973745f6f626a65637473203d207b7d0a6c6973745f70617274735f6261636b203d207b7d0a6c6973745f70617274735f66726f6e74203d207b7d0a6c6973745f70617274735f626c6f6f64203d207b7d0a6c6973745f7374657073203d207b7d0a6c6973745f6865616473203d207b7d0a0a66756e")
    (hex 256 "6374696f6e2066726e64286e290a0972657475726e20666c7228726e64286e29290a656e640a0a66756e6374696f6e2066726e6461286e2c206f290a096c6f63616c2061646476616c203d206f206f7220310a0972657475726e2066726e64286e292b61646476616c0a656e640a0a66756e6374696f6e2072616e6463286368616e6365290a096c6f63616c2063203d206368616e6365206f722035300a0969662066726e642831303029203c2063207468656e0a090972657475726e20747275650a09656e640a0972657475726e2066616c73650a656e640a0a66756e6374696f6e20777261702876616c75652c206d696e2c206d6178290a096966207661")
    (hex 512 "6c7565203c206d696e207468656e0a090972657475726e206d61780a09656c736569662076616c7565203e206d6178207468656e0a090972657475726e206d696e0a09656c73650a090972657475726e2076616c75650a09656e640a656e640a0a66756e6374696f6e207461626c655f636c6561722874290a096c6f63616c20636f756e74203d2023740a09666f7220693d302c20636f756e7420646f20745b695d3d6e696c20656e640a656e640a0a66756e6374696f6e20636f70795f73637265656e5f746f5f6d656d28290a092d2d2068616c6620746865206d61702f6c6f77657220737072697465206d656d6f727920617265610a096d656d63707928")
    (hex 768 "3078313830302c203078363030302c20307830383030290a092d2d20616c6d6f737420616c6c2067656e6572616c20757365206d656d6f72790a096d656d637079283078343330302c203078363830302c20307831383030290a656e640a0a66756e6374696f6e2070617374655f73637265656e5f66726f6d5f6d656d28290a096d656d637079283078363030302c203078313830302c20307830383030290a096d656d637079283078363830302c203078343330302c20307831383030290a656e640a0a66756e6374696f6e207072696e74635f6f287374722c20792c20636f6c2c206f7574636f6c2c207829202d2d207072696e7420612063656e746572")
    (hex 1024 "656420737472696e672077697468206120626c61636b206f75746c696e650a09666f7220693d2d312c3120646f0a092009666f72206a3d2d312c3120646f0a09202020097072696e7463287374722c20792b6a2c206f7574636f6c206f7220322c202878206f72203634292b69290a092009656e640a09656e640a097072696e7463287374722c20792c20636f6c2c202878206f7220363429290a656e640a0a66756e6374696f6e207072696e7463287374722c20792c20636f6c2c2078290a097072696e74287374722c202878206f72203634292d237374722a322c20792c20636f6c206f722037290a656e640a0a0a66756e6374696f6e207072696e7473")
    (hex 1280 "7072697465287374722c20792c20636f6c6f72290a0970616c28372c20636f6c6f72290a09666f7220693d312c202373747220646f0a0a09096c6f63616c206c65747465722c207768696368616c706861203d20737562287374722c692c69292c202d310a0909666f72206a20696e20616c6c28675f616c7068616265745f737072697465732920646f0a0909097768696368616c706861202b3d20310a0909096966206c6574746572203d3d206a207468656e0a0909090973707228313331202b20666c72287768696368616c7068612f39292a3136202b207768696368616c706861202520392c2036342d28237374722a38292f32202b2028692d31292a")
    (hex 1536 "382c2079290a09090909627265616b0a090909656e640a0909656e640a09656e640a0970616c28290a656e640a0a66756e6374696f6e207365745f6f75746c696e6528290a0970616c28322c20675f636f6c6f725f6f75746c696e65290a656e640a0a66756e6374696f6e206d5f74657874666c6f617428782c792c20746578742c20636f6c5f6d61696e2c20636f6c5f736563290a09616464286c6973745f70617274735f66726f6e742c0a097b0a0909783d782c0a0909793d792c0a0909746578743d746578742c0a0909636f6c5f6d61696e3d636f6c5f6d61696e206f7220372c0a0909636f6c5f7365633d636f6c5f736563206f7220352c0a090964")
    (hex 1792 "75723d33302c0a09096475725f6f7269673d33302c0a0a0909647261773d66756e6374696f6e2873656c66290a0909096c6f63616c20636f6c6f72203d2073656c662e636f6c5f6d61696e0a09090969662073656c662e647572203c2073656c662e6475725f6f7269672f33207468656e0a09090909636f6c6f72203d2073656c662e636f6c5f7365630a090909656e640a0909097072696e74635f6f2873656c662e746578742c2073656c662e792c20636f6c6f722c20675f636f6c6f725f6f75746c696e652c2073656c662e78290a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a09090973656c662e6475722d3d310a")
    (hex 2048 "09090969662073656c662e647572203d3d2030207468656e0a0909090964656c286c6973745f70617274735f66726f6e742c2073656c66290a090909656c73650a0909090973656c662e79202d3d202e330a090909656e640a0909656e642c0a097d290a656e640a0a66756e6374696f6e20615f7365745f696e76756c6e5f666c6173682873656c66290a0969662073656c662e696e76756c6e5f6672616d6573203e203020616e642073656c662e696e76756c6e5f6672616d657320252035203c2033207468656e0a0909666f7220693d312c313520646f0a09090970616c28692c2032290a0909656e640a090972657475726e20747275650a09656e640a")
    (hex 2304 "0972657475726e2066616c73650a656e640a0a66756e6374696f6e2069735f6e6561725f6f626a73286f626a312c206f626a322c2072616e6765290a09696620616273286f626a312e782d6f626a322e7829203c3d2072616e676520616e6420616273286f626a312e792d6f626a322e7929203c3d2072616e6765207468656e0a090972657475726e20747275650a09656e640a0972657475726e2066616c73650a656e640a0a66756e6374696f6e20696e745f636f6c732865312c2065322c20627566666572290a0969662065312e6a7573745f737061776e6564206f722065322e6a7573745f737061776e6564207468656e0a090972657475726e206661")
    (hex 2560 "6c73650a09656e640a096c6f63616c20627566666572203d20627566666572206f7220300a096c6f63616c2078312c2079312c2077312c2068312c2078322c2079322c2077322c206832203d0a0909090965312e782d65312e636f6c5f772f322d6275666665722c0a0909090965312e792d65312e636f6c5f682f322d6275666665722c0a090909200965312e636f6c5f772b6275666665722a322c0a090909200965312e636f6c5f682b6275666665722a322c0a0909090965322e782d65322e636f6c5f772f322d6275666665722c0a0909090965322e792d65322e636f6c5f682f322d6275666665722c0a0909090965322e636f6c5f772b627566666572")
    (hex 2816 "2a322c0a0909090965322e636f6c5f682b6275666665722a320a0969662078312b77313c7832206f722078322b77323c7831206f722079312b68313c7932206f722079322b68323c7931207468656e0a2020202072657475726e2066616c73650a09656c73650a20200972657475726e20747275650a09656e640a656e640a0a66756e6374696f6e206d5f706172745f626c6f6f6428706172745f64657461696c732c206475726174696f6e290a09706172745f64657461696c735b365d203d206475726174696f6e206f722066726e64612831302c203530290a096d5f706172745f616e676c6528706172745f64657461696c732c202e36352c20382c2067")
    (hex 3072 "5f636f6c6f725f626c6f6f645f6275726e290a656e640a0a66756e6374696f6e206d5f706172745f616e676c6528706172745f64657461696c732c2066726963742c20636f6c6f722c20636f6c6f725f7365632c206c61796572290a0a096c6f63616c2070203d0a097b0a090973697a653d706172745f64657461696c735b315d2d312c0a0909783d706172745f64657461696c735b325d2c0a0909793d706172745f64657461696c735b335d2c0a0909616e676c653d706172745f64657461696c735b345d2c0a090973706565645f6d6f76653d706172745f64657461696c735b355d2c0a09096475726174696f6e3d706172745f64657461696c735b365d")
    (hex 3328 "2c0a090966726963743d66726963742c0a0909636f6c6f723d636f6c6f722c0a0909636f6c6f725f7365633d636f6c6f725f736563206f7220636f6c6f722c0a09096c617965723d6c61796572206f7220302c0a0a090974696d653d302c0a0a0909647261773d66756e6374696f6e2873656c66290a0909096c6f63616c20636f6c6f722c207332203d2073656c662e636f6c6f722c2073656c662e73697a652f320a09090969662073656c662e74696d65203e2073656c662e6475726174696f6e202a2e3735207468656e0a09090909636f6c6f72203d2073656c662e636f6c6f725f7365630a090909656e640a09090969662073656c662e73697a65203d")
    (hex 3584 "3d2030207468656e0a09090909707365742873656c662e782c2073656c662e792c20636f6c6f72290a090909656c73650a090909097265637466696c6c2873656c662e782d73322c2073656c662e792d73322c2073656c662e782b73322c2073656c662e792b73322c20636f6c6f72290a090909656e640a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a09090969662073656c662e74696d65203e2073656c662e6475726174696f6e207468656e0a0909090969662073656c662e6c61796572203d3d2031207468656e0a090909090964656c286c6973745f70617274735f6261636b2c2073656c66290a09090909656c73")
    (hex 3840 "6569662073656c662e6c61796572203d3d2032207468656e0a090909090964656c286c6973745f70617274735f66726f6e742c2073656c66290a09090909656c73650a090909090964656c286c6973745f70617274735f626c6f6f642c2073656c66290a09090909656e640a0a0909090972657475726e0a090909656e640a09090969662073656c662e73706565645f6d6f7665203e202e31207468656e0a09090909615f6d6f76655f616e676c652873656c66290a0909090973656c662e73706565645f6d6f7665202a3d2073656c662e66726963740a090909656e640a09090973656c662e74696d65202b3d20310a0909656e642c0a097d0a096966206c")
    (hex 4096 "61796572203d3d2031207468656e0a0909616464286c6973745f70617274735f6261636b2c2070290a09656c73656966206c61796572203d3d2032207468656e0a0909616464286c6973745f70617274735f66726f6e742c2070290a09656c73650a0909616464286c6973745f70617274735f626c6f6f642c2070290a09656e640a0972657475726e20700a656e640a0a66756e6374696f6e206d5f706172745f737072697465286672616d652c20782c792c2064792c20636f6c2c20636f6c5f7365632c206475726174696f6e2c20666c6970782c2069735f66726f6e74290a0a096c6f63616c2070203d0a097b0a0909783d782c0a0909793d792c0a0909")
    (hex 4352 "6672616d653d6672616d652c0a0909636f6c3d636f6c2c0a0909636f6c5f7365633d636f6c5f736563206f7220636f6c2c0a09096475726174696f6e3d6475726174696f6e2c0a0909666c6970783d666c697078206f722066616c73652c0a090969735f66726f6e743d69735f66726f6e74206f722066616c73652c0a0a090974696d653d302c0a090964783d302c0a090964793d64792c0a09096464793d302c0a0a0909647261773d66756e6374696f6e2873656c66290a09090969662073656c662e74696d65203c2073656c662e6475726174696f6e202a2e3735207468656e0a0909090970616c28372c73656c662e636f6c290a090909656c73650a09")
    (hex 4608 "09090970616c28372c73656c662e636f6c5f736563290a090909656e640a0909097370722873656c662e6672616d652c2073656c662e782d342c2073656c662e792d342c20312c20312c2073656c662e666c697078290a09090970616c28290a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a09090973656c663a7570646174655f6261736528290a0909656e642c0a0a09097570646174655f626173653d66756e6374696f6e2873656c66290a09090969662073656c662e74696d65203e2073656c662e6475726174696f6e207468656e0a0909090969662073656c662e69735f66726f6e74207468656e0a090909090964")
    (hex 4864 "656c286c6973745f70617274735f66726f6e742c2073656c66290a09090909656c73650a090909090964656c286c6973745f70617274735f6261636b2c2073656c66290a09090909656e640a0909090972657475726e0a090909656e640a09090973656c662e78202b3d2073656c662e64780a09090973656c662e79202b3d2073656c662e64790a09090973656c662e6479202b3d2073656c662e6464790a09090973656c662e74696d65202b3d20310a0909656e642c0a097d0a0969662069735f66726f6e74207468656e0a0909616464286c6973745f70617274735f66726f6e742c2070290a09656c73650a0909616464286c6973745f70617274735f62")
    (hex 5120 "61636b2c2070290a09656e640a0972657475726e20700a656e640a0a66756e6374696f6e206d5f706172745f626f6d625f737061726b28782c2079290a096c6f63616c20636f6c6f722c20636f6c6f725f7365636f6e64203d2031302c20390a0969662072616e64632829207468656e0a0909636f6c6f722c20636f6c6f725f7365636f6e64203d20372c2031300a09656e640a096c6f63616c2070203d206d5f706172745f737072697465283130332c20782c20792c202d2e322d726e64282e35292c20636f6c6f722c20636f6c6f725f7365636f6e642c2031302b726e642835292c2066616c73652c2074727565290a09702e646479203d202e310a096c")
    (hex 5376 "6f63616c206478203d20726e64282e35290a0969662072616e64632829207468656e0a09096478203d2030202d2064780a09656e640a09702e6478203d2064780a656e640a0a66756e6374696f6e206d5f706172745f636972636c6528782c792c2073697a652c206475726174696f6e2c20636f6c6f722c20636f6c6f725f7365632c206c61796572290a0a096c6f63616c2070203d206d5f706172745f616e676c65287b73697a652c20782c20792c20302c20302c206475726174696f6e7d2c20302c20636f6c6f722c20636f6c6f725f7365632c206c61796572290a09702e647261773d66756e6374696f6e2873656c66290a09096c6f63616c20636f6c")
    (hex 5632 "6f72203d2073656c662e636f6c6f720a090969662073656c662e74696d65203e2073656c662e6475726174696f6e202a202e3735207468656e0a090909636f6c6f72203d2073656c662e636f6c6f725f7365630a0909656e640a09096369726366696c6c2873656c662e782c2073656c662e792c2073656c662e73697a652c20636f6c6f72290a09656e640a656e640a0a66756e6374696f6e206d5f706172745f626c6f6f6473706c61736828782c792c616e676c65290a0a09666f7220693d302c333620646f0a09096c6f63616c2073697a652c20786f66662c20796f66662c20616e676c656f66662c6475723d312c20726e642834292c20726e64283429")
    (hex 5888 "2c20726e64282e32292c20726e642838290a090969662069203e203330207468656e0a0909096475723d726e642831290a09090973697a653d320a0909656c736569662069203e203135207468656e0a0909096475723d726e642834290a0909656e640a09096d5f706172745f626c6f6f64287b73697a652c20782d322b786f66662c20792d322b796f66662c20616e676c652d2e312b616e676c656f66662c206475727d290a09656e640a0a656e640a0a66756e6374696f6e206d5f706172745f696d7061637428656e746974792c73697a65290a096d5f706172745f636972636c6528656e746974792e782c20656e746974792e792c2073697a65206f72")
    (hex 6144 "20372c20342c2031302c20392c2031290a656e640a0a66756e6374696f6e2068616e646c655f736c6173685f7265636f76657279287370656564290a096c6f63616c20646972203d20726e64282e313235290a0969662072616e64632829207468656e0a0909646972203d20302d6469720a09656e640a0a0970312e736c6173685f616e676c652c2070312e736c6173685f73706565642c2070312e736c6173685f74696d652c2070312e736c6173685f6861735f696d706163746564203d0a096162732870312e736c6173685f616e676c652b2e352b6469722925312c207370656564206f7220302c20352c20747275650a09615f616e696d5f7365742870")
    (hex 6400 "312c202261747461636b22290a656e640a0a66756e6374696f6e2068616e646c655f736c6173685f656e746974795f696d7061637428746172676574290a0a0963616d3a7368616b65282e312c2033290a202067616d655f706175736528322c2030290a096966206e6f74207461726765742e69735f6675726e6974757265207468656e0a09096d5f706172745f626c6f6f6473706c617368287461726765742e782c207461726765742e792c2070312e736c6173685f616e676c65290a09656e640a0a096d5f706172745f696d70616374287461726765742c203130290a0968616e646c655f736c6173685f7265636f7665727928290a656e640a0a66756e")
    (hex 6656 "6374696f6e2073636f72655f61646428656e746974792c2073636f7265290a0969662073636f7265203e2030207468656e0a0909736678286d696e2832362b666c722873636f72652f31292c20333129290a09656c73650a0909736678283332290a09656e640a0a2020675f73636f72655f6c6576656c202b3d2073636f72650a0a20206c6f63616c2073636f72655f636f6c6f722c2073636f72655f636f6c6f725f736563203d2031302c20390a202069662073636f7265203e3d2034207468656e0a2020202073636f72655f636f6c6f722c2073636f72655f636f6c6f725f736563203d20372c20390a2020656c736569662073636f7265203e3d203220")
    (hex 6912 "7468656e0a2020202073636f72655f636f6c6f722c2073636f72655f636f6c6f725f736563203d2031312c20330a09656c736569662073636f7265203c2030207468656e0a090973636f72655f636f6c6f722c2073636f72655f636f6c6f725f736563203d20382c2031330a2020656e640a0969662073636f726520213d2030207468656e0a2020096d5f74657874666c6f617428656e746974792e782c20656e746974792e792d382c2022222e2e73636f72652a31302c2073636f72655f636f6c6f722c2073636f72655f636f6c6f725f736563290a09656e640a656e640a0a66756e6374696f6e20617474656d70745f6465666c6563745f746172676574")
    (hex 7168 "28746172676574290a0a096c6f63616c20726576657273655f616e676c65203d20616273287461726765742e616e676c652b2e352925310a0a096966206162732870312e736c6173685f616e676c65202d20726576657273655f616e676c6529203c202e3235207468656e0a0a09097366782838290a09096d5f706172745f636972636c65287461726765742e782c207461726765742e792c20362c2031302c20372c20352c2031290a0a09097461726765742e69735f666c79696e672c207461726765742e69735f666c79696e675f696d7061637461626c652c207461726765742e77696e6475705f74696d655f72656d2c207461726765742e6174746163")
    (hex 7424 "6b5f74696d655f72656d2c207461726765742e666c795f7370656564203d0a0909747275652c2066616c73652c20302c20302c20320a0a09096c6f63616c20745f646972203d20726e64282e313235290a090969662072616e64632829207468656e0a090909745f646972203d2030202d20745f6469720a0909656e640a09097461726765742e616e676c653d206162732870312e736c6173685f616e676c652b745f6469722925310a09092d2d7461726765743a656d6f74696f6e5f61646428290a0a09092d2d20746f646f202d20636f6d62696e65207468697320776974682068616e646c652d696d706163742076657273696f6e20696e746f20612073")
    (hex 7680 "696e676c652066756e6374696f6e0a0a090968616e646c655f736c6173685f7265636f766572792832290a090972657475726e20747275650a09656e640a0972657475726e2066616c73650a656e640a0a66756e6374696f6e20636f6d626f28656e746974792c20746172676574290a09656e746974792e7761735f636f756e7465645f666f725f636f6d626f203d20747275650a0a097366782866726e646128322c20323129290a0968616e646c655f696d706163745f646561746828656e746974792c20746172676574290a0a096966206e6f7420656e746974792e69735f6675726e6974757265207468656e0a09096d5f706172745f626c6f6f647370")
    (hex 7936 "6c617368287461726765742e782c207461726765742e792c20656e746974792e616e676c65290a09656e640a0a097461726765743a68616e646c655f696d7061637428656e74697479290a097461726765742e666c795f73706565642c207461726765742e616e676c65203d20656e746974792e666c795f73706565642c20656e746974792e616e676c6525310a0a09696620656e746974792e69735f6865617679206f7220656e746974792e69735f61726d6f726564207468656e0a09097461726765742e73636f72655f6d756c7469706c696572203d20656e746974792e73636f72655f6d756c7469706c6965720a0909666c795f726573657428656e74")
    (hex 8192 "697479290a0909656e746974792e696e76756c6e5f6672616d6573203d2031350a0909696620656e746974792e69735f61726d6f726564207468656e0a09090961747461636b5f726573657428656e74697479290a0909656e640a09656c73650a09097461726765742e73636f72655f6d756c7469706c696572203d20656e746974792e73636f72655f6d756c7469706c696572202b20310a09656e640a656e640a0a66756e6374696f6e20736c6173685f74617267657428746172676574290a0a09736678283235290a097461726765742e666c795f73706565642c207461726765742e616e676c65203d20332c2070312e736c6173685f616e676c650a09")
    (hex 8448 "7461726765743a68616e646c655f696d7061637428290a0968616e646c655f736c6173685f656e746974795f696d7061637428746172676574290a09615f616e696d5f7365742870312c202261747461636b22290a656e640a0a66756e6374696f6e20615f616e696d5f75706461746528656e746974792c20616e696d5f7365742c207469636b5f6d756c7469706c696572290a096966207469636b5f6d756c7469706c696572203d3d206e696c207468656e0a09097469636b5f6d756c7469706c696572203d20310a09656e640a09656e746974792e616e696d7469636b2d3d31202a207469636b5f6d756c7469706c6965720a09696620656e746974792e")
    (hex 8704 "616e696d7469636b3c3d30207468656e0a0909656e746974792e6375726672616d652b3d310a09096c6f63616c20613d616e696d5f7365745b656e746974792e637572616e696d5d0a0a0909656e746974792e616e696d7469636b3d612e7469636b730a0909696620656e746974792e6375726672616d653e23612e6672616d6573207468656e0a090909656e746974792e6375726672616d653d310a0909656e640a09656e640a656e640a0a66756e6374696f6e20615f616e696d5f73657428656e746974792c20616e696d290a09696628616e696d3d3d656e746974792e637572616e696d2972657475726e0a0a09656e746974792e616e696d7469636b")
    (hex 8960 "2c20656e746974792e637572616e696d2c20656e746974792e6375726672616d65203d206368617261637465725f616e696d735b616e696d5d2e7469636b732c20616e696d2c20310a656e640a0a66756e6374696f6e20615f646f666c69707828656e74697479290a096c6f63616c20616e676c65203d20656e746974792e616e676c650a09696620616e676c65203d3d202e3235206f7220616e676c65203d3d202e3735207468656e0a090972657475726e0a09656c7365696620616e676c65203e202e323520616e6420616e676c65203c202e3735207468656e0a0909656e746974792e666c697078203d20747275650a09656c73650a0909656e746974")
    (hex 9216 "792e666c697078203d2066616c73650a09656e640a656e640a0a66756e6374696f6e20636f6e73747261696e5f746f5f73637265656e286f626a290a0972657475726e20636f6e73747261696e5f746f5f626f7264657273286f626a2c20675f6c6576656c5f73637265656e5f6275666665722b342c20675f6c6576656c5f73637265656e5f6275666665722b342c203132342d675f6c6576656c5f73637265656e5f6275666665722c203132342d675f6c6576656c5f73637265656e5f627566666572290a656e640a0a66756e6374696f6e20636f6e73747261696e5f746f5f626f7264657273286f626a2c20626f725f78312c20626f725f79312c20626f")
    (hex 9472 "725f78322c20626f725f7932290a0a096c6f63616c207761735f636f6e73747261696e65642c20782c2079203d2066616c73652c206f626a2e782c206f626a2e790a0969662078203c20626f725f7831207468656e0a0909782c207761735f636f6e73747261696e6564203d20626f725f78312c20747275650a09656c736569662078203e20626f725f7832207468656e0a0909782c207761735f636f6e73747261696e6564203d20626f725f78322c20747275650a09656e640a0969662079203c20626f725f7931207468656e0a0909792c207761735f636f6e73747261696e6564203d20626f725f79312c20747275650a09656c736569662079203e2062")
    (hex 9728 "6f725f7932207468656e0a0909792c207761735f636f6e73747261696e6564203d20626f725f79322c20747275650a09656e640a096f626a2e782c206f626a2e79203d20782c20790a0972657475726e207761735f636f6e73747261696e65640a656e640a0a66756e6374696f6e2067616d655f7061757365286475726174696f6e290a0967616d655f70617573655f74696d6572203d206475726174696f6e0a656e640a0a66756e6374696f6e2068616e646c655f696d706163745f646561746828656e746974792c20746172676574290a096966206e6f7420656e746974792e69735f6675726e697475726520616e64206e6f7420656e746974792e6973")
    (hex 9984 "5f61726d6f726564207468656e0a090973706c69745f656e7469747928656e746974792c2028656e746974792e616e676c652b2e35292531290a09096d5f706172745f626c6f6f6473706c617368287461726765742e782c207461726765742e792c20656e746974792e616e676c65290a09096966207461726765742e69735f6865617679207468656e0a0909096966206e6f74207461726765742e69735f626c6f6f6479207468656e0a090909097461726765742e737072697465202b3d2031360a090909097461726765742e69735f626c6f6f6479203d20747275650a090909656e640a0909656e640a09656e640a096d5f706172745f696d7061637428")
    (hex 10240 "656e74697479290a0963616d3a7368616b65282e352a656e746974792e666c795f73706565642c3130290a202067616d655f70617573652832290a0a09696620656e746974792e69735f76696c6c61676572207468656e0a09096c6576656c5f656e645f76696c6c616765725f646965642866616c7365290a09656e640a096966206e6f7420656e746974792e69735f686561767920616e64206e6f7420656e746974792e69735f61726d6f726564207468656e0a20200964656c5f66726f6d5f70656f706c6528656e74697479290a090973636f72655f61646428656e746974792c20656e746974792e73636f7265202a20656e746974792e73636f72655f")
    (hex 10496 "6d756c7469706c696572290a09656e640a656e640a0a66756e6374696f6e20666c795f726573657428656e74697479290a09656e746974792e666c795f73706565642c20656e746974792e69735f666c79696e672c20656e746974792e69735f666c79696e675f696d7061637461626c652c20656e746974792e616e676c652c20656e746974792e73636f72655f6d756c7469706c696572203d0a09302c2066616c73652c2066616c73652c206765745f6469725f746f5f706c6179657228656e74697479292c20310a656e640a0a66756e6374696f6e2061747461636b5f726573657428656e74697479290a09656e746974792e61747461636b5f74696d65")
    (hex 10752 "5f72656d2c20656e746974792e7265636f766572795f74696d655f72656d2c20656e746974792e74696d655f6265747765656e5f61747461636b735f72656d203d0a09302c20656e746974792e7265636f766572795f74696d652c20656e746974792e74696d655f6265747765656e5f61747461636b732b656e746974792e7265636f766572795f74696d650a656e640a0a66756e6374696f6e20615f61747461636b28656e74697479290a0a09656e746974792e61747461636b5f74696d655f72656d202d3d20310a09615f6d6f76655f616e676c6528656e746974792c2034290a09696620636f6e73747261696e5f746f5f73637265656e28656e746974")
    (hex 11008 "7929207468656e0a0909736678283230290a090961747461636b5f726573657428656e74697479290a09656e640a0a09696620656e746974792e61747461636b5f74696d655f72656d203c3d2030207468656e0a090961747461636b5f726573657428656e74697479290a09656e640a656e640a0a66756e6374696f6e20615f666c7928656e74697479290a09615f6d6f76655f616e676c6528656e746974792c20656e746974792e666c795f7370656564290a09656e746974792e666c795f7370656564202a3d202e39350a0a096c6f63616c207761735f7265736574203d2066616c73650a0a2020696620656e746974792e666c795f7370656564203c3d")
    (hex 11264 "202e31207468656e0a0909666c795f726573657428656e74697479290a09097761735f7265736574203d20747275650a2020656e640a0a09696620636f6e73747261696e5f746f5f73637265656e28656e7469747929207468656e0a0909656e746974792e616e676c652c20656e746974792e666c795f7370656564203d206765745f7265626f756e645f616e676c655f737065656428656e746974792e616e676c652c20656e746974792e666c795f7370656564290a09096d5f706172745f696d7061637428656e74697479290a0909656e746974792e69735f666c79696e675f696d7061637461626c65203d2066616c73650a0909736678283233290a09")
    (hex 11520 "656e640a0a096966206e6f74207761735f726573657420616e6420656e746974792e69735f666c79696e675f696d7061637461626c65207468656e0a0909666f72206120696e20616c6c286c6973745f70656f706c652920646f0a09092d2d096966206e6f7420612e69735f666c79696e67207468656e0a09090909696620656e7469747920213d206120616e6420612e696e76756c6e5f6672616d6573203d3d203020616e6420696e745f636f6c7328656e746974792c20612c203229207468656e0a0909090909696620656e746974792e666c795f7370656564203e202e35207468656e0a090909090909636f6d626f28656e746974792c61290a090909")
    (hex 11776 "090909627265616b0a0909090909656e640a09090909656e640a09092d2d09656e640a0909656e640a09656e640a656e640a0a66756e6374696f6e20615f6d6f76655f616e676c6528656e746974792c207370656564290a096966206e6f74207370656564207468656e0a09097370656564203d20656e746974792e73706565645f6d6f76650a09656e640a0a09656e746974792e616e676c65203d2061627328656e746974792e616e676c652925310a09615f646f666c69707828656e74697479290a0a09656e746974792e78202b3d20636f7328656e746974792e616e676c6529202a2073706565640a09656e746974792e79202b3d2073696e28656e74")
    (hex 12032 "6974792e616e676c6529202a2073706565640a656e640a0a6368617261637465725f616e696d73203d0a7b0a095b227374616e64225d3d0a097b0a09097469636b733d31303030302c0a0909686672616d65733d7b317d2c0a09096672616d65733d7b31347d2c0a097d2c0a095b226d6f7665225d3d0a097b0a09097469636b733d362c0a0909686672616d65733d7b312c312c312c317d2c0a09096672616d65733d7b31322c31332c31342c31357d2c0a097d2c0a095b2272756e225d3d202d2d20746869732069732061206861636b2062656361757365206f6e6c792076696c6c61676572732072756e0a097b0a09097469636b733d372c0a0909686672")
    (hex 12288 "616d65733d7b31372c31382c31372c31387d2c0a09096672616d65733d7b31322c31332c31342c31357d2c0a097d2c0a095b2277696e647570225d3d0a097b0a09097469636b733d31303030302c0a0909686672616d65733d7b31377d2c0a09096672616d65733d7b34357d2c0a097d2c0a095b2261747461636b225d3d0a097b0a09097469636b733d31303030302c0a0909686672616d65733d7b33337d2c0a09096672616d65733d7b34367d2c0a097d2c0a095b22666c79225d3d0a097b0a09097469636b733d31303030302c0a0909686672616d65733d7b34397d2c0a09096672616d65733d7b34377d2c0a097d2c0a7d0a0a0a66756e6374696f6e20")
    (hex 12544 "6765745f646972656374696f6e5f746f5f7475726e286375725f616e676c652c20646573697265645f616e676c65290a096c6f63616c20616e676c655f64656c7461203d20646573697265645f616e676c652d6375725f616e676c650a0a096c6f63616c207475726e5f726573756c74203d20300a096966202d2e35203c20616e676c655f64656c746120616e6420616e676c655f64656c7461203c3d202e35207468656e0a09097475726e5f726573756c74203d20616e676c655f64656c74610a09656c7365696620616e676c655f64656c7461203e202e35207468656e0a09097475726e5f726573756c74203d20616e676c655f64656c7461202d20310a")
    (hex 12800 "09656c7365696620616e676c655f64656c7461203c3d202d2e35207468656e0a09097475726e5f726573756c74203d20616e676c655f64656c7461202b20310a09656e640a0a096966207475726e5f726573756c74203c2030207468656e0a090972657475726e20310a09656c73650a090972657475726e202d310a09656e640a656e640a0a66756e6374696f6e206765745f7265626f756e645f616e676c655f737065656428616e676c652c207370656564290a096c6f63616c20646972203d202d2e3132350a0969662072616e64632829207468656e0a0909646972203d202e3132350a09656e640a0972657475726e2028616e676c652b2e352b646972")
    (hex 13056 "2925312c207370656564202a202e350a656e640a0a66756e6374696f6e206765745f616e676c655f66726f6d5f696e70757428290a0969662070312e7265636f766572795f74696d655f72656d203e2030207468656e0a090972657475726e20300a09656e640a096c6f63616c206d6c2c206d722c206d752c206d642c20616e676c65203d2062746e2830292c2062746e2831292c2062746e2832292c2062746e2833292c202d310a096966206d6c207468656e0a09096966206d64207468656e0a090909616e676c65203d202e3632350a0909656c73656966206d75207468656e0a090909616e676c65203d202e3337350a0909656c73650a090909616e67")
    (hex 13312 "6c65203d202e350a0909656e640a09656c73656966206d72207468656e0a09096966206d64207468656e0a090909616e676c65203d202e3837350a0909656c73656966206d75207468656e0a090909616e676c65203d202e3132350a0909656c73650a090909616e676c65203d20300a0909656e640a09656c73656966206d64207468656e0a0909616e676c65203d202e37350a09656c73656966206d75207468656e0a0909616e676c65203d202e32350a09656e640a0972657475726e20616e676c650a656e640a0a2d2d20726564756374696f6e203a2072656d6f766520636f6c5f772c20636f6c5f6820616e64206a7573742068617665206f6e652073")
    (hex 13568 "717561726520636f6c2e2072656d6f766520636f6c5f6f66662e2072656d6f766520632b6f20696e206f66667365742c206a75737420646f202d3420676c6f62616c0a0a66756e6374696f6e206d5f706c6179657228736574782c2073657479290a0a096c6f63616c20703d0a097b0a09096e616d65203d2022222c0a090970636f6c6f723d372c0a090973636f6c6f723d362c0a090969735f706c61796572203d20747275652c0a0909783d736574782c0a0909793d736574792c0a0909616e676c653d302c0a090973706565645f6d6f76653d302c0a090973706565645f6d6f76655f6d61783d312e32352c0a0909636f6c5f773d362c0a0909636f6c5f")
    (hex 13824 "683d362c0a0909636f6c5f6f66663d302c0a0a0909637572616e696d3d226d6f7665222c0a09096375726672616d653d312c0a0909616e696d7469636b3d302c0a0909666c6970783d747275652c0a0909686561645f73686966743d302c0a0909626f64795f73686966743d302c0a0a2020202068705f6375723d322c0a090969735f646561643d66616c73652c0a0a202020207265636f766572795f74696d655f72656d203d20302c0a090972656164795f74696d65203d203135302c0a20202020696e76756c6e5f6672616d6573203d20302c0a090969735f736c617368696e67203d2066616c73652c0a0a0a0909696e69743d66756e6374696f6e2873")
    (hex 14080 "656c66290a0909656e642c0a0a2020202064616d6167653d66756e6374696f6e2873656c662c20736f757263652c20646f5f6b696c6c290a20202020202069662073656c662e696e76756c6e5f6672616d6573203e203020616e64206e6f7420646f5f6b696c6c207468656e0a202020202020202072657475726e2066616c73650a202020202020656e640a0a0909096c6f63616c20626c6f6f645f616e676c65203d206174616e322873656c662e78202d20736f757263652e782c2073656c662e79202d20736f757263652e79290a0909096d5f706172745f626c6f6f6473706c6173682873656c662e782c2073656c662e792c20626c6f6f645f616e676c")
    (hex 14336 "65290a20202020202067616d655f70617573652835290a20202020202063616d3a7368616b6528332c203230290a0a090909675f706c617965725f64616d616765645f74696d652c2073656c662e696e76756c6e5f6672616d6573203d2031302c2036300a0a09090973656c662e68705f637572202d3d20310a20202020202069662073656c662e68705f637572203c3d2030206f7220675f646966666963756c7479203e2034206f7220646f5f6b696c6c207468656e0a0909090973656c662e69735f646561642c2073656c662e686561645f7368696674203d20747275652c20300a0909090973706c69745f656e746974792873656c662c2028626c6f6f")
    (hex 14592 "645f616e676c652b2e35292531290a09090909736678283130290a20202020202020206c6576656c5f656e645f706c617965725f6469656428736f757263652e69735f737461746963290a202020202020656c73650a090909097366782866726e6461283229290a090909656e640a0a20202020202072657475726e20747275650a20202020656e642c0a0a0a0909736c6173683d66756e6374696f6e2873656c66290a0909096966206e6f742073656c662e69735f736c617368696e67207468656e0a0a090909097366782866726e646128332c3429290a09090909615f616e696d5f7365742873656c662c202277696e64757022290a0909090973656c66")
    (hex 14848 "2e736c6173685f6861735f696d7061637465642c0a0909090973656c662e69735f736c617368696e672c0a0909090973656c662e736c6173685f74696d652c0a0909090973656c662e736c6173685f73706565642c0a0909090973656c662e736c6173685f616e676c652c0a0909090973656c662e73706565645f6d6f76652c0a0909090973656c662e72656164795f74696d65203d0a0909090966616c73652c0a09090909747275652c0a09090909352c0a09090909362c0a0909090973656c662e616e676c652c0a09090909302c0a0909090934350a090909656e640a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a09")
    (hex 15104 "090969662073656c662e69735f64656164207468656e0a0909090972657475726e0a090909656e640a0a09090969662073656c662e72656164795f74696d65203e2030207468656e0a0909090973656c662e72656164795f74696d65202d3d20310a0909090969662073656c662e72656164795f74696d65203d3d2030207468656e0a09090909097366782837290a09090909656e640a090909656e640a0a090909636865636b5f666f725f666f6f7473746570732873656c66290a0a0909092d2d20626c6f6f6420647269702066726f6d2064616d6167650a0a0909096c6f63616c20626c6f6f645f72617465203d20300a09090969662073656c662e6870")
    (hex 15360 "5f637572203c2032207468656e0a09090909626c6f6f645f72617465203d20320a090909656e640a090909696620626c6f6f645f72617465203e2030207468656e0a09090909696620675f7469636b73202520626c6f6f645f72617465203d3d2030207468656e0a09090909096c6f63616c2073697a65203d20310a090909090969662072616e646328313029207468656e0a09090909090973697a65203d20320a0909090909656e640a09090909096d5f706172745f626c6f6f64287b73697a652c2073656c662e782d322c2073656c662e792d322c20726e642831292c20726e642831292c2066726e646128332c3130297d290a09090909656e640a0909")
    (hex 15616 "09656e640a0a09090969662073656c662e696e76756c6e5f6672616d6573203e2030207468656e0a0909090973656c662e696e76756c6e5f6672616d6573202d3d20310a090909656e640a0a09090969662073656c662e7265636f766572795f74696d655f72656d203e2030207468656e0a0909090973656c662e7265636f766572795f74696d655f72656d202d3d20310a090909092d2d615f616e696d5f7365742873656c662c20227374616e6422290a0909090972657475726e0a090909656e640a0a09090969662062746e70283429207468656e0a0909090969662073656c662e72656164795f74696d65203d3d2030207468656e0a09090909097365")
    (hex 15872 "6c663a736c61736828290a09090909656e640a090909656e640a0a09090969662073656c662e69735f736c617368696e67207468656e0a0a0909090973656c662e736c6173685f74696d65202d3d20310a090909096d5f706172745f7370726974652834392c2073656c662e782c2073656c662e792c20302c2031322c20312c2031302c2073656c662e666c6970782c2066616c7365290a0a0909090973656c662e78202b3d20636f732873656c662e736c6173685f616e676c6529202a2073656c662e736c6173685f73706565640a0909090973656c662e79202b3d2073696e2873656c662e736c6173685f616e676c6529202a2073656c662e736c617368")
    (hex 16128 "5f73706565640a0a09090909696620636f6e73747261696e5f746f5f73637265656e2873656c6629207468656e0a0909090909736678283233290a090909090973656c662e736c6173685f616e676c652c2073656c662e736c6173685f7370656564203d206765745f7265626f756e645f616e676c655f73706565642873656c662e736c6173685f616e676c652c2073656c662e736c6173685f7370656564290a0a09090909096d5f706172745f696d706163742873656c66290a09090909656e640a0a0909090969662073656c662e736c6173685f74696d65203d3d2030207468656e0a090909090973656c662e69735f736c617368696e672c2073656c66")
    (hex 16384 "2e7265636f766572795f74696d655f72656d203d2066616c73652c2031300a0909090909615f616e696d5f7365742873656c662c202261747461636b22290a09090909656e640a090909656c73650a090909096c6f63616c20696e7075745f616e676c65203d206765745f616e676c655f66726f6d5f696e70757428290a0a09090909696620696e7075745f616e676c65203e3d2030207468656e0a09090909092d2d5b5b0a090909090969662028696e7075745f616e676c652b2e35292531203d3d2073656c662e616e676c65207468656e0a09090909090973656c662e73706565645f6d6f7665203d20300a0909090909656e640a09090909092d2d5d5d")
    (hex 16640 "0a090909090973656c662e616e676c652c2073656c662e73706565645f6d6f766520203d20696e7075745f616e676c652c2073656c662e73706565645f6d6f76655f6d61780a0909090909615f6d6f76655f616e676c652873656c66290a0909090909615f616e696d5f7365742873656c662c20226d6f766522290a09090909656c73650a090909090973656c662e73706565645f6d6f7665203d20300a0909090909615f616e696d5f7365742873656c662c20227374616e6422290a09090909656e640a0a09090909696620636f6e73747261696e5f746f5f73637265656e2873656c6629207468656e0a090909090973656c662e73706565645f6d6f7665")
    (hex 16896 "203d20300a09090909656e640a090909656e640a0a090909615f616e696d5f7570646174652873656c662c206368617261637465725f616e696d73290a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a09090969662073656c662e69735f64656164207468656e0a0909090972657475726e0a090909656e640a09090969662073656c662e72656164795f74696d65203d3d203020616e64202873656c662e637572616e696d203d3d20226d6f766522206f722073656c662e637572616e696d203d3d20227374616e642229207468656e0a0909090973656c662e626f64795f73686966742c2073656c662e686561645f73686966")
    (hex 17152 "74203d2031362c2031360a090909656c73650a0909090973656c662e626f64795f73686966742c2073656c662e686561645f7368696674203d20302c20300a090909656e640a090909647261775f6368617261637465722873656c66290a0909656e642c0a097d0a0a09703a696e697428290a09616464286c6973745f6472617773747566662c2070290a0972657475726e20700a656e640a0a656d6f74696f6e5f616e696d73203d0a7b0a095b227570736574225d3d0a097b0a09097469636b733d372c0a09096672616d65733d7b37302c37317d2c0a097d2c0a095b22616e677279225d3d0a097b0a09097469636b733d372c0a09096672616d65733d7b")
    (hex 17408 "37322c37332c37302c37347d2c0a097d2c0a7d0a0a66756e6374696f6e206d5f656d6f74696f6e28656e746974792c20656d6f74696f6e290a096c6f63616c2065203d0a097b0a09096f776e65723d656e746974792c0a0909637572616e696d3d656d6f74696f6e2c0a09096375726672616d653d312c0a0909616e696d7469636b3d302c0a0909636f6c6f723d675f636f6c6f725f696e746572666163652c0a0a09097570646174653d66756e6374696f6e2873656c66290a090909615f616e696d5f7570646174652873656c662c20656d6f74696f6e5f616e696d73290a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a0909")
    (hex 17664 "096c6f63616c206672616d652c20635f6f203d20656d6f74696f6e5f616e696d735b73656c662e637572616e696d5d2e6672616d65735b73656c662e6375726672616d655d2c202d340a09090970616c28372c2073656c662e636f6c6f72290a0a090909737072286672616d652c0a0909090973656c662e6f776e65722e782b635f6f2c0a0909090973656c662e6f776e65722e792b635f6f2d31302c0a09090909312c312c2066616c7365290a09090970616c28290a0909656e642c0a097d0a09656e746974792e656d6f74696f6e203d20650a656e640a0a2d2d5d5d0a0a66756e6374696f6e206765745f666c6970785f66726f6d5f616e676c6528616e")
    (hex 17920 "676c65290a09696620616e676c65203e202e323520616e6420616e676c65203c3d202e3735207468656e0a090972657475726e20747275650a09656e640a0972657475726e2066616c73650a656e640a0a66756e6374696f6e206765745f6469725f746f5f706c6179657228656e74697479290a0972657475726e20286174616e3228656e746974792e78202d2070312e782c20656e746974792e79202d2070312e79292b2e352925310a656e640a0a66756e6374696f6e206765745f79626f626f66667365742873656c66290a0a0969662073656c662e637572616e696d203d3d20226d6f766522207468656e0a090969662073656c662e6375726672616d")
    (hex 18176 "6520252032203d3d2030207468656e0a09090972657475726e202d310a0909656e640a09656e640a0972657475726e20300a656e640a0a66756e6374696f6e206d5f7374657028782c79290a096c6f63616c2073203d0a097b0a0909783d782d66726e646128342c32292c0a0909793d792c0a097d0a09616464286c6973745f73746570732c2073290a656e640a0a66756e6374696f6e20636865636b5f666f725f666f6f7473746570732873656c66290a092d2d20646f20736e6f772073747566660a09696620675f736561736f6e203d3d203320616e64206e6f7420675f6c6576656c5f696e646f6f72207468656e0a090969662072616e646328353029")
    (hex 18432 "207468656e0a0909096d5f737465702873656c662e782c2073656c662e79290a0909656e640a09656e640a656e640a0a66756e6374696f6e20647261775f6368617261637465722873656c66290a0a096c6f63616c2079626f626f6666736574203d206765745f79626f626f66667365742873656c66290a0a096966206e6f7420615f7365745f696e76756c6e5f666c6173682873656c6629207468656e0a090970616c28362c73656c662e73636f6c6f72290a090970616c28372c73656c662e70636f6c6f72290a09656e640a0a096c6f63616c20666c69705f6f6666736574203d202d310a0969662073656c662e666c697078207468656e0a0909666c69")
    (hex 18688 "705f6f6666736574203d20310a09656e640a097365745f6f75746c696e6528290a09737072286368617261637465725f616e696d735b73656c662e637572616e696d5d2e686672616d65735b73656c662e6375726672616d655d2b73656c662e686561645f73686966742c0a090973656c662e782d342c0a090973656c662e792d372b79626f626f66667365742c0a0909312c312c0a090973656c662e666c697078290a09737072286368617261637465725f616e696d735b73656c662e637572616e696d5d2e6672616d65735b73656c662e6375726672616d655d2b73656c662e626f64795f73686966742c0a090973656c662e782d342b666c69705f6f66")
    (hex 18944 "667365742c0a090973656c662e792b312b79626f626f66667365742c0a0909312c312c0a090973656c662e666c697078290a0970616c28290a656e640a0a66756e6374696f6e2073706c69745f656e7469747928656e746974792c20616e676c65290a096d5f626f64797061727428656e746974792c2034322c20656e746974792e70636f6c6f722c2028616e676c652b2e3330302b726e64282e33323529292531290a096d5f626f64797061727428656e746974792c2035362b656e746974792e686561645f73686966742c20656e746974792e73636f6c6f722c2061627328616e676c652d2e3330302d726e64282e33323529292531290a656e640a0a66")
    (hex 19200 "756e6374696f6e20726e64626f6f6c28290a0972657475726e2066726e64283229203d3d20300a656e640a0a66756e6374696f6e206d5f626f64797061727428656e746974792c207370726974652c207265706c6163655f636f6c6f722c20616e676c65290a096c6f63616c20683d0a097b0a0909783d656e746974792e782c0a0909793d656e746974792e792c0a09097265706c6163655f636f6c6f72203d207265706c6163655f636f6c6f722c0a0909616e676c653d616e676c652c0a09097370726974653d7370726974652c0a090973706565645f6d6f76653d2e352b726e64282e35292c0a0a0909666c69705f783d726e64626f6f6c28292c0a0a09")
    (hex 19456 "0964656361795f74696d653d66726e64612832352c3235292c0a0a09097570646174653d66756e6374696f6e2873656c66290a0a0a0909092d2d20696620776520726f6c6c20746f20612073746f702c20737461727420636f756e74696e6720646f776e20636c65616e75700a09090969662073656c662e73706565645f6d6f7665203c202e31207468656e0a0909090973656c662e64656361795f74696d65202d3d20310a0909090969662073656c662e64656361795f74696d65203c2030207468656e0a090909090964656c286c6973745f68656164732c2073656c66290a090909090964656c286c6973745f6472617773747566662c2073656c66290a")
    (hex 19712 "090909090972657475726e0a09090909656e640a090909656c73650a09090909696620675f7469636b7320252036203d3d2030207468656e0a09090909096c6f63616c2073697a65203d20310a090909090969662072616e646328333329207468656e0a09090909090973697a65203d20320a0909090909656e640a0909090909096d5f706172745f626c6f6f64287b73697a652c2073656c662e782c2073656c662e792c20302c202e32352b726e64282e35297d290a09090909656e640a090909656e640a0a090909615f6d6f76655f616e676c652873656c66290a0a09090973656c662e73706565645f6d6f7665202a3d202e39350a0a09090969662063")
    (hex 19968 "6f6e73747261696e5f746f5f73637265656e2873656c6629207468656e0a0909090973656c662e616e676c652c2073656c662e73706565645f6d6f7665203d206765745f7265626f756e645f616e676c655f73706565642873656c662e616e676c652c2073656c662e73706565645f6d6f7665290a090909656e640a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a0a0909096c6f63616c20635f6f203d202d340a0a0909097365745f6f75746c696e6528290a09090970616c28362c2073656c662e7265706c6163655f636f6c6f72290a0a0909097370722873656c662e7370726974652c0a0909090973656c662e782b635f6f")
    (hex 20224 "2c0a0909090973656c662e792b312b635f6f2c0a09090909312c312c0a0909090973656c662e666c69705f78290a09090970616c28290a0909656e642c0a097d0a09616464286c6973745f68656164732c2068290a09616464286c6973745f6472617773747566662c2068290a0972657475726e20680a656e640a0a66756e6374696f6e206d5f6f626a65637428782c20792c207370726974656c6973742c2069735f646561646c79290a096c6f63616c206f203d0a097b0a0909783d782c0a0909793d792c0a0909636f6c5f773d342c0a0909636f6c5f683d322c0a09097370726974656c6973743d7370726974656c6973742c0a09097370726974653d31")
    (hex 20480 "2c0a090969735f7374617469633d747275652c0a090969735f646561646c793d69735f646561646c792c0a0a09097570646174653d66756e6374696f6e2873656c66290a0909656e642c0a0a09096465616c745f64616d6167653d66756e6374696f6e2873656c66290a09090973656c662e737072697465203d20320a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a0909097365745f6f75746c696e6528290a09090970616c2831342c2038290a09090970616c28312c20675f636f6c6f725f64657461696c290a0909097370722873656c662e7370726974656c6973745b73656c662e7370726974655d2c20782d342c20792d")
    (hex 20736 "34290a09090970616c28290a0909656e642c0a097d0a09616464286c6973745f6f626a656374732c206f290a09616464286c6973745f6472617773747566662c206f290a0972657475726e206f0a656e640a0a66756e6374696f6e206d5f666f6f6428736574782c2073657479290a096c6f63616c206f203d206d5f6f626a65637428736574782c20736574792c207b39392c2039397d2c2066616c7365290a096f2e636f6c5f682c206f2e636f6c5f772c206f2e656174203d0a09362c20362c0a0966756e6374696f6e2873656c66290a090970312e68705f637572203d20320a09096d5f706172745f737072697465283130362c2073656c662e782c2073")
    (hex 20992 "656c662e792c202d2e312c20675f636f6c6f725f6f75746c696e652c20675f636f6c6f725f6f75746c696e652c2031352c2066616c73652c2074727565290a090973636f72655f6164642873656c662c2035290a090964656c286c6973745f6f626a656374732c2073656c66290a090964656c286c6973745f6472617773747566662c2073656c66290a09656e640a656e640a0a66756e6374696f6e206164645f746f5f70656f706c6528656e74697479290a0a09696620656e746974792e69735f76696c6c61676572207468656e0a0909616464286c6973745f76696c6c61676572732c20656e74697479290a09656c73650a0909616464286c6973745f65")
    (hex 21248 "6e656d6965732c20656e74697479290a09656e640a0a09616464286c6973745f70656f706c652c20656e74697479290a09616464286c6973745f6472617773747566662c20656e74697479290a656e640a0a66756e6374696f6e2064656c5f66726f6d5f70656f706c6528656e74697479290a09696620656e746974792e69735f76696c6c61676572207468656e0a090964656c286c6973745f76696c6c61676572732c20656e74697479290a09656c73656966206e6f7420656e746974792e69735f6675726e6974757265207468656e0a090964656c286c6973745f656e656d6965732c20656e74697479290a09656e640a0964656c286c6973745f70656f")
    (hex 21504 "706c652c20656e74697479290a0964656c286c6973745f6472617773747566662c20656e74697479290a09696620236c6973745f656e656d696573203d3d203020616e6420675f6c6576656c5f656e656d6965735f636f756e74203d3d2030207468656e0a09096c6576656c5f656e645f77696e28290a09656e640a656e640a0a66756e6374696f6e20615f616c6572745f636865636b666f7277696e64757028656e74697479290a0969662069735f6c6576656c5f616374697665282920616e6420656e746974792e77696e6475705f74696d655f72656d203d3d203020616e642069735f6e6561725f6f626a7328656e746974792c2070312c20656e7469")
    (hex 21760 "74792e616c6572745f64697374616e636529207468656e0a0909656e746974792e77696e6475705f74696d655f72656d2c20656e746974792e646573697265645f616e676c65203d0a0909656e746974792e77696e6475705f74696d652d656e746974792e656d6f74696f6e5f636f756e742a332c206765745f6469725f746f5f706c6179657228656e74697479290a0a0909656e746974792e666c697078203d206765745f666c6970785f66726f6d5f616e676c6528656e746974792e646573697265645f616e676c65290a0909615f616e696d5f73657428656e746974792c202277696e64757022290a090972657475726e20747275650a09656c73650a")
    (hex 22016 "090972657475726e2066616c73650a09656e640a656e640a0a66756e6374696f6e20615f6465766961746528656e746974792c2074696d65290a0969662072616e646328313029207468656e0a0909656e746974792e646576696174696f6e5f74696d65203d2066726e64612874696d652c2074696d65290a09656e640a656e640a0a66756e6374696f6e20615f72616e646f6d5f7475726e28656e74697479290a096c6f63616c20616e676c655f61646a757374203d202e32350a0969662072616e64632829207468656e0a0909616e676c655f61646a757374203d20302d616e676c655f61646a7573740a09656e640a0a09656e746974792e616e676c65")
    (hex 22272 "5f64657369726564203d2061627328656e746974792e616e676c655f646573697265642b616e676c655f61646a7573742925310a656e640a0a66756e6374696f6e206d5f656e656d795f76696c6c6167657228736574782c2073657479290a096c6f63616c2065203d206d5f656e656d7928736574782c20736574792c2074727565290a2020652e686561645f73686966742c20652e626f64795f73686966742c20652e70636f6c6f722c20652e73636f6c6f722c20652e73636f7265203d0a09362c2031362c2031312c20342c202d31300a0a09652e6b696c6c5f636c6173733d66756e6374696f6e2873656c662c20736f75726365290a0909696620736f")
    (hex 22528 "75726365203d3d207031207468656e0a0909096c6576656c5f656e645f76696c6c616765725f646965642874727565290a0909656c73650a0909096c6576656c5f656e645f76696c6c616765725f646965642866616c7365290a0909656e640a090972657475726e2066616c73650a09656e640a0a09652e746f7563685f636c6173733d66756e6374696f6e2873656c66290a090973636f72655f6164642873656c662c20302d73656c662e73636f72652d322e352a73656c662e656d6f74696f6e5f636f756e74290a090964656c5f66726f6d5f70656f706c652873656c66290a090972657475726e20747275650a09656e640a0a09652e6d6f76653d6675")
    (hex 22784 "6e6374696f6e2873656c66290a0909615f646576696174652873656c662c2035290a0909615f72616e646f6d5f7475726e2873656c66290a09656e640a0a09652e647261775f636c6173733d66756e6374696f6e2873656c66290a09656e640a0a0972657475726e20650a656e640a0a66756e6374696f6e206e6561726573745f616e676c6528616e676c65290a09696620616e676c653e2e383235206f7220616e676c65203c202e313235207468656e0a0909616e676c65203d20300a09656c7365696620616e676c65203c202e333735207468656e0a0909616e676c65203d202e32350a09656c7365696620616e676c65203c202e363235207468656e0a")
    (hex 23040 "0909616e676c65203d202e350a09656c73650a0909616e676c65203d202e37350a09656e640a0972657475726e20616e676c650a656e640a0a66756e6374696f6e206d5f6172726f7728782c20792c20616e676c65290a096c6f63616c2061203d0a097b0a0909783d782c0a0909793d792c0a0909636f6c5f773d342c0a0909636f6c5f683d342c0a0909616e676c653d616e676c652c0a090973706565645f6d6f76653d332c0a090969735f7374617469633d66616c73652c0a090969735f646561646c793d747275652c0a09097370726974653d34302c0a0909666c6970783d66616c73652c0a0a0909647261773d66756e6374696f6e2873656c66290a")
    (hex 23296 "0909097365745f6f75746c696e6528290a0909097370722873656c662e7370726974652c2073656c662e782d342c2073656c662e792d342c20312c20312c2073656c662e666c697078290a09090970616c28290a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a090909615f6d6f76655f616e676c652873656c66290a090909696620636f6e73747261696e5f746f5f73637265656e2873656c6629207468656e0a0909090973656c663a6465616c745f64616d61676528290a090909656e640a0909656e642c0a0a09096465616c745f64616d6167653d66756e6374696f6e2873656c66290a09090964656c286c6973745f")
    (hex 23552 "6f626a656374732c2073656c66290a09090964656c286c6973745f6472617773747566662c2073656c66290a0909656e642c0a097d0a09696620616e676c65203d3d202e3235206f7220616e676c65203d3d2e3735207468656e0a0909612e737072697465203d2034310a09656e640a0a09616464286c6973745f6f626a656374732c2061290a09616464286c6973745f6472617773747566662c2061290a656e640a0a66756e6374696f6e206d5f656e656d795f61726368657228736574782c2073657479290a096c6f63616c2065203d206d5f656e656d7928736574782c2073657479290a09652e686561645f73686966742c20652e70636f6c6f722c20")
    (hex 23808 "652e73636f6c6f722c20652e616c6572745f64697374616e63652c20652e77696e6475705f74696d652c20652e74696d655f6265747765656e5f61747461636b732c20652e61747461636b5f74696d652c20652e61747461636b5f69735f73686f74203d20342c2031342c2031332c2036302c2033302c2036302c2033302c20747275650a0a09652e6d6f76653d66756e6374696f6e2873656c66290a0909615f646576696174652873656c662c203130290a090969662069735f6c6576656c5f6163746976652829207468656e0a09090973656c662e616e676c655f64657369726564203d206765745f6469725f746f5f706c617965722873656c66290a09")
    (hex 24064 "09656e640a09656e640a0a09652e616c6572745f636c6173733d66756e6374696f6e2873656c66290a09096966206162732873656c662e78202d2070312e7829203c2035206f72206162732873656c662e79202d2070312e7929203c2035207468656e0a090909696620615f616c6572745f636865636b666f7277696e6475702873656c6629207468656e0a0909090973656c662e646573697265645f616e676c65203d206e6561726573745f616e676c652873656c662e646573697265645f616e676c65290a09090909736678283234290a0909090972657475726e20747275650a090909656c73650a0909090972657475726e2066616c73650a09090965")
    (hex 24320 "6e640a0909656e640a09656e640a0a09652e666972655f6172726f773d66756e6374696f6e2873656c66290a0909736678283137290a09096d5f6172726f772873656c662e782c2073656c662e792c2073656c662e646573697265645f616e676c65290a09656e640a0a09652e647261775f636c6173733d66756e6374696f6e2873656c66290a090969662073656c662e77696e6475705f74696d655f72656d203e2030207468656e0a0909097365745f6f75746c696e6528290a0909096c6f63616c206172726f775f7370726974652c20646f666c697079203d2034302c2066616c73650a09090969662073656c662e646573697265645f616e676c65203d")
    (hex 24576 "3d202e3735207468656e0a090909096172726f775f7370726974652c20646f666c697079203d2034312c20747275650a090909656c736569662073656c662e646573697265645f616e676c65203d3d202e3235207468656e0a090909096172726f775f737072697465203d2034310a090909656e640a090909737072286172726f775f7370726974652c2073656c662e782d342c2073656c662e792d342c20312c20312c2073656c662e666c6970782c20646f666c697079290a09090970616c28290a0909656e640a09656e640a656e640a0a66756e6374696f6e206d5f656e656d795f77616e64657228736574782c2073657479290a096c6f63616c206520")
    (hex 24832 "3d206d5f656e656d7928736574782c2073657479290a0a09652e686561645f73686966742c20652e70636f6c6f72203d20312c20390a0a09652e6d6f76653d66756e6374696f6e2873656c66290a0909615f646576696174652873656c662c203135290a0909615f72616e646f6d5f7475726e2873656c66290a09656e640a0a09652e616c6572745f636c6173733d66756e6374696f6e2873656c66290a090972657475726e20615f616c6572745f636865636b666f7277696e6475702873656c66290a09656e640a0a0972657475726e20650a656e640a0a66756e6374696f6e206d5f656e656d795f626f6d62657228736574782c2073657479290a096c6f")
    (hex 25088 "63616c2065203d206d5f656e656d7928736574782c2073657479290a0a2009652e70636f6c6f722c20652e73636f6c6f722c20652e686561645f73686966742c20652e69735f667573655f6c69742c20652e69735f626f6d626572203d0a09382c20342c20332c2066616c73652c20747275650a0a09652e746f7563685f636c6173733d66756e6374696f6e2873656c66290a090973656c663a6578706c6f6465286e696c2c2074727565290a090972657475726e20747275650a09656e640a0a09652e7570646174655f636c6173733d66756e6374696f6e2873656c66290a09096966206e6f742073656c662e69735f667573655f6c697420616e64206973")
    (hex 25344 "5f6e6561725f6f626a732873656c662c2070312c20323529207468656e0a09090973656c662e69735f667573655f6c69742c2073656c662e667573655f74696d65722c2073656c662e656d6f74696f6e5f636f756e742c2073656c662e73706565645f6d6f7665203d20747275652c203530302c20312c2073656c662e73706565645f6d6f76655f6f7269672a320a090909736678283335290a0909656e640a090969662073656c662e69735f667573655f6c6974207468656e0a09090973656c662e667573655f74696d6572202d3d20310a09090969662073656c662e667573655f74696d6572203c3d2030207468656e0a0909090973656c663a6578706c")
    (hex 25600 "6f64652873656c662c2074727565290a090909656e640a090909696620675f7469636b7320252034203d3d2030207468656e0a090909096d5f706172745f626f6d625f737061726b2873656c662e782c2073656c662e792d3130290a090909656e640a0909656e640a090972657475726e20747275650a09656e640a0a09652e6d6f76653d66756e6374696f6e2873656c66290a0a0909615f646576696174652873656c662c203130290a090969662069735f6c6576656c5f6163746976652829207468656e0a09090973656c662e616e676c655f64657369726564203d206765745f6469725f746f5f706c617965722873656c66290a0909656e640a09656e")
    (hex 25856 "640a0a09652e6578706c6f64653d66756e6374696f6e2873656c662c20736f757263652c206e6f5f73636f7265290a0909696620736f7572636520213d206e696c20616e6420736f7572636520213d20703120616e64206e6f7420736f757263652e69735f6865617679207468656e0a09090973656c662e73636f72655f6d756c7469706c696572203d20736f757263652e73636f72655f6d756c7469706c696572202b20310a0909656e640a0a09096966206e6f742073656c662e7761735f636f756e7465645f666f725f636f6d626f207468656e0a09090973656c662e7761735f636f756e7465645f666f725f636f6d626f203d20747275650a09090973")
    (hex 26112 "66782866726e646128322c333329290a0909096d5f706172745f636972636c652873656c662e782c2073656c662e792c2032302c20362c2031302c20382c2032290a0a090909666f7220693d2d362c20362c203220646f0a09090909666f72206a3d2d362c20362c203220646f0a090909090969662072616e646328373529207468656e0a0909090909096c6f63616c2073697a65203d2066726e64612832290a0a0909090909096d5f706172745f626c6f6f64287b73697a652c2073656c662e782b692c2073656c662e792b6a2c20096174616e322873656c662e78202d202873656c662e782b69292c2073656c662e79202d202873656c662e792b6a2929")
    (hex 26368 "2c20726e642832297d290a0909090909656e640a09090909656e640a090909656e640a09090973706c69745f656e746974792873656c662c20726e64283129290a09090963616d3a7368616b6528332c203130290a09090967616d655f70617573652832290a0a0909096966206e6f74206e6f5f73636f7265207468656e0a0909090973636f72655f6164642873656c662c2073656c662e73636f7265202a2073656c662e73636f72655f6d756c7469706c696572290a090909656e640a0909656e640a0a0909666f72206120696e20616c6c286c6973745f70656f706c652920646f0a0909096966206120213d2073656c6620616e64206120213d20736f75")
    (hex 26624 "726365207468656e0a090909096966206e6f7420612e7761735f636f756e7465645f666f725f636f6d626f20616e64206e6f7420612e6a7573745f737061776e656420616e64206e6f7420612e69735f61726d6f726564207468656e0a090909090969662069735f6e6561725f6f626a732873656c662c20612c20323029207468656e0a090909090909696620736f7572636520213d206e696c20616e64206e6f7420736f757263652e69735f6865617679207468656e0a09090909090909736f757263652e73636f72655f6d756c7469706c696572202b3d20310a090909090909656e640a0909090909096966206e6f7420612e69735f6675726e69747572")
    (hex 26880 "65207468656e0a09090909090909696620612e69735f626f6d626572207468656e0a0909090909090909613a6b696c6c2873656c662c206e6f5f73636f7265290a09090909090909656c73656966206e6f7420612e69735f6865617679207468656e0a0909090909090909613a6b696c6c2873656c662c2074727565290a09090909090909656e640a090909090909656e640a0909090909092d2d206f6e6c7920666f722070656f706c652074686174206469646e2774206578706c6f64650a0909090909096966206e6f7420612e7761735f636f756e7465645f666f725f636f6d626f20616e64206e6f7420612e69735f6865617679207468656e0a090909")
    (hex 27136 "0909090973656c662e73636f72655f6d756c7469706c696572202b3d20310a09090909090909612e7761735f636f756e7465645f666f725f636f6d626f203d20747275650a090909090909096966206e6f74206e6f5f73636f7265207468656e0a090909090909090973636f72655f61646428612c20612e73636f7265202a2073656c662e73636f72655f6d756c7469706c696572290a09090909090909656e640a090909090909656e640a0a0909090909656e640a09090909656e640a090909656e640a0909656e640a090969662069735f6e6561725f6f626a732873656c662c2070312c20323029207468656e0a09090970313a64616d6167652873656c")
    (hex 27392 "66290a0909656e640a0a090964656c5f66726f6d5f70656f706c652873656c66290a0a09656e640a0a09652e68616e646c655f696d706163745f636c6173733d66756e6374696f6e2873656c662c20736f75726365290a090973656c663a6578706c6f646528736f75726365290a090972657475726e20747275650a09656e640a0a09652e6b696c6c5f636c6173733d66756e6374696f6e2873656c662c20736f757263652c206e6f5f73636f7265290a090973656c663a6578706c6f646528736f757263652c206e6f5f73636f7265290a090972657475726e20747275650a09656e640a0a09652e647261775f636c6173733d66756e6374696f6e2873656c")
    (hex 27648 "66290a09096c6f63616c20785f6f6666203d202d350a090969662073656c662e666c697078207468656e0a090909785f6f6666203d202d330a0909656e640a09097365745f6f75746c696e6528290a09097370722832302c2073656c662e782b785f6f66662c2073656c662e792d31322b6765745f79626f626f66667365742873656c66292c20312c20312c2073656c662e666c697078290a090970616c28290a09656e640a0a0972657475726e20650a656e640a0a66756e6374696f6e206d5f656e656d795f626f737328736574782c2073657479290a096c6f63616c2065203d206d5f656e656d795f7365656b657228736574782c2073657479290a0965")
    (hex 27904 "2e69735f61726d6f7265642c20652e686561645f73686966742c20652e70636f6c6f722c20652e73636f6c6f722c20652e73706565645f6d6f76655f6f726967203d20747275652c20352c2031332c20362c202e350a09653a696e697428290a656e640a0a66756e6374696f6e206d5f656e656d795f7365656b657228736574782c2073657479290a0a096c6f63616c2065203d206d5f656e656d7928736574782c2073657479290a0a09652e686561645f7368696674203d20320a09652e6d6f76653d66756e6374696f6e2873656c66290a0909615f646576696174652873656c662c203130290a0a090969662069735f6c6576656c5f6163746976652829")
    (hex 28160 "207468656e0a09090973656c662e616e676c655f64657369726564203d206765745f6469725f746f5f706c617965722873656c66290a0909656e640a09656e640a0a09652e616c6572745f636c6173733d66756e6374696f6e2873656c66290a090972657475726e20615f616c6572745f636865636b666f7277696e6475702873656c66290a09656e640a0a0972657475726e20650a656e640a0a66756e6374696f6e206d5f656e656d795f6675726e697475726528736574782c20736574792c207370726974652c2069735f6865617679290a096c6f63616c2065203d206d5f656e656d7928736574782c2073657479290a0a09652e7570646174655f636c")
    (hex 28416 "6173733d66756e6374696f6e2873656c66290a090969662073656c662e69735f666c79696e67207468656e0a090909636865636b5f666f725f666f6f7473746570732873656c66290a090909615f666c792873656c66290a09092020656e640a090972657475726e2066616c73650a09656e640a0a09652e6b696c6c5f636c6173733d66756e6374696f6e2873656c66290a09202064656c5f66726f6d5f70656f706c652873656c66290a090972657475726e20747275650a09656e640a0a09652e746f7563685f636c6173733d66756e6374696f6e2873656c66290a090972657475726e20747275650a09656e640a0a09652e7370726974652c20652e6973")
    (hex 28672 "5f6675726e69747572652c20652e69735f6865617679203d207370726974652c20747275652c2069735f6865617679206f722066616c73650a0a0964656c286c6973745f656e656d6965732c2065290a0972657475726e20650a656e640a0a66756e6374696f6e206d5f656e656d7928736574782c20736574792c2069735f76696c6c61676572290a096c6f63616c20653d0a097b0a0909783d736574782c0a0909793d736574792c0a090970636f6c6f723d31302c0a090973636f6c6f723d372c0a090969735f76696c6c61676572203d2069735f76696c6c61676572206f722066616c73652c0a0a0909616e676c653d302c0a0909616e676c655f646573")
    (hex 28928 "697265643d302c0a0909616c6572745f64697374616e63653d31352c0a090973706565645f7475726e3d2e30312c0a090973706565645f6d6f76655f6f7269673d2e32352b726e64282e31292c0a090973706565645f6d6f76653d302c0a0a090977696e6475705f74696d653d32352c0a090977696e6475705f74696d655f72656d3d302c0a0909646576696174696f6e5f74696d653d302c0a0a0909636f6c5f773d362c0a0909636f6c5f683d362c0a0909636f6c5f6f66663d302c0a0a0909637572616e696d3d226d6f7665222c0a09096375726672616d653d312c0a0909616e696d7469636b3d302c0a0909666c6970783d747275652c0a0a09096865")
    (hex 29184 "61645f73686966743d302c0a0909626f64795f73686966743d302c0a0a0909656d6f74696f6e3d6e696c2c0a0909656d6f74696f6e5f636f756e743d302c0a0909656d6f74696f6e5f74696d65723d302c0a0a0909666c795f73706565643d302c0a090969735f666c79696e673d66616c73652c0a0a090961747461636b5f74696d653d372c0a090961747461636b5f74696d655f72656d3d302c0a09097265636f766572795f74696d653d32302c0a09097265636f766572795f74696d655f72656d3d302c0a090974696d655f6265747765656e5f61747461636b733d302c0a090974696d655f6265747765656e5f61747461636b735f72656d3d302c0a0a")
    (hex 29440 "09096a7573745f737061776e65643d747275652c0a0a20202020696e76756c6e5f6672616d65733d302c0a090977616e6465725f74696d653d302c0a090977616e6465725f6469723d66726e642837292c0a0a2020202073636f72653d312c0a2020202073636f72655f6d756c7469706c6965723d312c0a09097761735f636f756e7465645f666f725f636f6d626f3d66616c73652c0a0a0909696e69743d66756e6374696f6e2873656c66290a09090969662069735f6c6576656c5f6163746976652829207468656e0a0909090973656c662e696e76756c6e5f6672616d65732c2073656c662e73706565645f6d6f76652c2073656c662e616e676c65203d")
    (hex 29696 "2033302c2073656c662e73706565645f6d6f76655f6f7269672c20286174616e322873656c662e78202d2070312e782c2073656c662e79202d2070312e79292b2e352925310a09090909636f6e73747261696e5f746f5f73637265656e2873656c66290a090909656e640a0909656e642c0a0a09096d6f76653d66756e6374696f6e2873656c66290a0909656e642c0a0a090961747461636b5f7461726765743d66756e6374696f6e2873656c66290a09090969662073656c662e61747461636b5f69735f73686f74207468656e0a0909090973656c663a666972655f6172726f7728290a0909090961747461636b5f72657365742873656c66290a09090909")
    (hex 29952 "72657475726e0a090909656e640a0a09090973656c662e61747461636b5f74696d655f72656d2c2073656c662e616e676c65203d2073656c662e61747461636b5f74696d652c2073656c662e646573697265645f616e676c650a090909615f616e696d5f7365742873656c662c202261747461636b22290a0909097366782866726e646128332c313829290a0909656e642c0a0a090968616e646c655f696d706163745f636c6173733d66756e6374696f6e2873656c66290a09090972657475726e2066616c73650a0909656e642c0a0a090968616e646c655f696d706163743d66756e6374696f6e2873656c662c20736f75726365290a0909096966206e6f")
    (hex 30208 "742073656c663a68616e646c655f696d706163745f636c61737328736f7572636529207468656e0a0909090973656c662e69735f666c79696e672c2073656c662e69735f666c79696e675f696d7061637461626c652c2073656c662e77696e6475705f74696d655f72656d2c2073656c662e61747461636b5f74696d655f72656d203d20747275652c20747275652c20302c20300a09090909615f616e696d5f7365742873656c662c2022666c7922290a0909090973656c663a656d6f74696f6e5f61646428290a090909096d5f706172745f696d706163742873656c66290a090909656e640a0909656e642c0a0a09096b696c6c5f636c6173733d66756e63")
    (hex 30464 "74696f6e2873656c66290a09090972657475726e2066616c73650a0909656e642c0a0a09096b696c6c3d66756e6374696f6e2873656c662c20736f757263652c206e6f5f73636f72652c20616e676c652c206f76657272696465290a0909096966206e6f74206f76657272696465207468656e0a0909090969662073656c663a6b696c6c5f636c61737328736f757263652c206e6f5f73636f726529207468656e0a090909090972657475726e0a09090909656e640a090909656e640a0a0909096c6f63616c20736f757263655f616e676c65203d20616e676c65206f72206174616e3228736f757263652e78202d2073656c662e782c20736f757263652e79")
    (hex 30720 "202d2073656c662e79290a0a0909096d5f706172745f626c6f6f6473706c6173682873656c662e782c2073656c662e792c20736f757263655f616e676c65290a0a09090973706c69745f656e746974792873656c662c20736f757263655f616e676c65290a0a0909096966206e6f74206e6f5f73636f7265207468656e0a0909090973636f72655f6164642873656c662c2073656c662e73636f7265290a090909656e640a09090964656c5f66726f6d5f70656f706c652873656c66290a0909656e642c0a0a0909616c6572745f636c6173733d66756e6374696f6e2873656c66290a09090972657475726e2066616c73650a0909656e642c0a0a0909746f75")
    (hex 30976 "63685f636c6173733d66756e6374696f6e2873656c66290a09090972657475726e2066616c73650a0909656e642c0a0a09097570646174655f636c6173733d66756e6374696f6e2873656c66290a09090972657475726e20747275650a0909656e642c0a0a09097570646174653d66756e6374696f6e2873656c66290a09090969662073656c662e696e76756c6e5f6672616d6573203e2030207468656e0a0909090973656c662e696e76756c6e5f6672616d6573202d3d20310a090909656c73650a0909090973656c662e6a7573745f737061776e6564203d2066616c73650a090909656e640a09090969662073656c662e6a7573745f737061776e656420")
    (hex 31232 "7468656e0a0909090972657475726e0a090909656e640a0a0909096966206e6f742073656c663a7570646174655f636c6173732829207468656e0a0909090973656c662e6a7573745f737061776e6564203d2066616c73650a0909090972657475726e0a090909656e640a0a090909636865636b5f666f725f666f6f7473746570732873656c66290a09090969662073656c662e69735f666c79696e67207468656e0a09090909615f666c792873656c66290a090909656c736569662073656c662e61747461636b5f74696d655f72656d203e2030207468656e0a09090909615f61747461636b2873656c66290a0a090909656c736569662073656c662e7769")
    (hex 31488 "6e6475705f74696d655f72656d203e2030207468656e0a0909090973656c662e77696e6475705f74696d655f72656d202d3d20310a0909090969662073656c662e77696e6475705f74696d655f72656d203c3d2030207468656e0a090909090973656c663a61747461636b5f74617267657428290a09090909656e640a090909656c736569662073656c662e7265636f766572795f74696d655f72656d203e2030207468656e0a0909090973656c662e7265636f766572795f74696d655f72656d202d3d20310a090909656c736569662073656c662e74696d655f6265747765656e5f61747461636b735f72656d203d3d203020616e642073656c663a616c65")
    (hex 31744 "72745f636c6173732829207468656e0a090909656c73650a0909090969662073656c662e74696d655f6265747765656e5f61747461636b735f72656d20203e2030207468656e0a090909090973656c662e74696d655f6265747765656e5f61747461636b735f72656d202d3d20310a09090909656e640a0909090969662073656c662e646576696174696f6e5f74696d65203e2030207468656e0a090909090973656c662e646576696174696f6e5f74696d65202d3d20310a09090909656c73650a090909090973656c663a6d6f766528290a0a09090909096966206162732873656c662e616e676c65202d2073656c662e616e676c655f6465736972656429")
    (hex 32000 "203c202e3035207468656e0a09090909090973656c662e616e676c655f646573697265643d73656c662e616e676c650a0909090909656e640a0a090909090969662073656c662e616e676c6520213d2073656c662e616e676c655f64657369726564207468656e0a09090909090973656c662e616e676c65203d202873656c662e616e676c65202b2073656c662e73706565645f7475726e2a6765745f646972656374696f6e5f746f5f7475726e2873656c662e616e676c655f646573697265642c2073656c662e616e676c6529290a0909090909656e640a09090909656e640a0909090909615f6d6f76655f616e676c652873656c66290a09090909096c6f")
    (hex 32256 "63616c20616e696d203d20226d6f7665220a090909090969662073656c662e69735f76696c6c6167657220616e642073656c662e656d6f74696f6e5f636f756e74203e2030207468656e0a090909090909616e696d203d202272756e220a0909090909656e640a0909090909615f616e696d5f7365742873656c662c20616e696d290a09090909696620636f6e73747261696e5f746f5f73637265656e2873656c6629207468656e0a090909090973656c662e616e676c65203d202873656c662e616e676c652b2e32352925310a09090909656e640a090909656e640a09090973656c663a656d6f74696f6e5f75706461746528290a0a090909615f616e696d")
    (hex 32512 "5f7570646174652873656c662c206368617261637465725f616e696d732c2073656c662e656d6f74696f6e5f636f756e742b31290a0909656e642c0a0a0909647261775f636c6173733d66756e6374696f6e2873656c66290a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a0909096966206e6f742073656c662e69735f6675726e6974757265207468656e0a09090909647261775f6368617261637465722873656c66290a0909090973656c663a647261775f636c61737328290a0909090969662073656c662e656d6f74696f6e20616e64206e6f742073656c662e69735f666c79696e67207468656e0a090909090973656c66")
    (hex 32768 "2e656d6f74696f6e3a6472617728290a09090909656e640a090909656c73650a090909097365745f6f75746c696e6528290a090909097370722873656c662e7370726974652c2073656c662e782d342c2073656c662e792d34290a0909090970616c28290a090909656e640a0909656e642c0a0a0909656d6f74696f6e5f7570646174653d66756e6374696f6e2873656c66290a09090969662073656c662e656d6f74696f6e207468656e0a0909090973656c662e656d6f74696f6e3a75706461746528290a090909656e640a09090969662073656c662e656d6f74696f6e5f74696d6572203e2030207468656e0a0909090973656c662e656d6f74696f6e5f")
    (hex 33024 "74696d6572202d3d20310a0909090969662073656c662e656d6f74696f6e5f74696d6572203d3d2030207468656e0a090909090973656c662e656d6f74696f6e5f636f756e74202d3d20310a090909090973656c663a656d6f74696f6e5f7365745f66726f6d5f636f756e7428290a090909090969662073656c662e656d6f74696f6e5f636f756e74203e2030207468656e0a09090909090973656c662e656d6f74696f6e5f74696d6572203d203336300a0909090909656e640a09090909656e640a090909656e640a0909656e642c0a0a0909656d6f74696f6e5f7365745f66726f6d5f636f756e743d66756e6374696f6e2873656c66290a090909696620")
    (hex 33280 "73656c662e656d6f74696f6e5f636f756e74203d3d2033207468656e0a090909096d5f656d6f74696f6e2873656c662c2022616e67727922290a090909656c736569662073656c662e656d6f74696f6e5f636f756e74203e3d2031207468656e0a090909096d5f656d6f74696f6e2873656c662c2022757073657422290a090909656c73650a0909090973656c662e656d6f74696f6e203d206e696c0a090909656e640a09090973656c662e73706565645f6d6f7665203d2073656c662e73706565645f6d6f76655f6f726967202b202e322a73656c662e656d6f74696f6e5f636f756e740a0a0909656e642c0a0a0909656d6f74696f6e5f6164643d66756e")
    (hex 33536 "6374696f6e2873656c66290a09090973656c662e656d6f74696f6e5f636f756e742c2073656c662e656d6f74696f6e5f74696d6572203d206d696e28332c2073656c662e656d6f74696f6e5f636f756e742b31292c203336300a09090973656c663a656d6f74696f6e5f7365745f66726f6d5f636f756e7428290a0909656e642c0a097d0a0a09653a696e697428290a0a096164645f746f5f70656f706c652865290a0972657475726e20650a656e640a0a66756e6374696f6e206765745f67656e5f636f6f72647328290a096c6f63616c2067656e5f782c2067656e5f792c20776869636873696465203d2066726e6428313238292c2066726e6428313238")
    (hex 33792 "292c2066726e642834290a09696620776869636873696465203d3d2030207468656e0a090967656e5f78203d20340a09656c7365696620776869636873696465203d3d2031207468656e0a090967656e5f78203d203132340a09656c7365696620776869636873696465203d3d2032207468656e0a090967656e5f79203d20340a09656c73650a090967656e5f79203d203132340a09656e640a0972657475726e2067656e5f782c2067656e5f790a656e640a0a66756e6374696f6e206d5f656e656d795f72616e646f6d28290a0a096c6f63616c20656e656d795f74797065203d20675f656e656d795f776569676874735b66726e64612823675f656e656d")
    (hex 34048 "795f77656967687473295d0a0a09696620656e656d795f74797065203d3d2035207468656e0a09096966206e6f7420675f737061776e65645f626f7373207468656e0a0909096d5f656e656d795f626f7373286765745f67656e5f636f6f7264732829290a090909675f737061776e65645f626f7373203d20747275650a0909656c73650a09090972657475726e0a0909656e640a09656c7365696620656e656d795f74797065203d3d2031207468656e0a09096d5f656e656d795f77616e646572286765745f67656e5f636f6f7264732829290a09656c7365696620656e656d795f74797065203d3d2032207468656e0a09096d5f656e656d795f7365656b")
    (hex 34304 "6572286765745f67656e5f636f6f7264732829290a09656c7365696620656e656d795f74797065203d3d2033207468656e0a09096d5f656e656d795f617263686572286765745f67656e5f636f6f7264732829290a09656c73650a09096d5f656e656d795f626f6d626572286765745f67656e5f636f6f7264732829290a09656e640a0909675f6c6576656c5f656e656d6965735f636f756e74202d3d20310a656e640a0a66756e6374696f6e207365745f63616d5f706f7328706f73290a09696620706f732b383c3634207468656e0a0909706f732b3d6d696e2836342d28706f732b38292c34290a09656e640a09696620706f732d383e3634207468656e")
    (hex 34560 "0a0909706f732b3d6d696e2836342d28706f732d38292c34290a09656e640a0972657475726e20706f730a656e640a0a66756e6374696f6e206d5f63616d28290a0963616d65726128290a096c6f63616c20633d0a097b0a0909706f735f78203d2036342c0a0909706f735f79203d2036342c0a0a09097368616b655f72656d61696e696e673d302c0a09097368616b655f666f7263653d302c0a0a09097570646174653d66756e6374696f6e2873656c66290a09090973656c662e7368616b655f72656d61696e696e672c2073656c662e706f735f792c2073656c662e706f735f78203d206d617828302c73656c662e7368616b655f72656d61696e696e67")
    (hex 34816 "2d31292c206d69642836342c207365745f63616d5f706f732873656c662e706f735f79292c20393630292c206d69642836342c207365745f63616d5f706f732873656c662e706f735f78292c20393630290a09090963616d6572612873656c663a63616d5f706f732829290a0909656e642c0a0a090963616d5f706f733d66756e6374696f6e2873656c66290a0909096c6f63616c2073686b5f782c2073686b5f792c20666f726365203d20302c20302c2073656c662e7368616b655f666f7263650a0a09090969662073656c662e7368616b655f72656d61696e696e673e30207468656e0a0909090973686b5f782c2073686b5f79203d20726e6428666f72")
    (hex 35072 "6365292d666f7263652f322c20726e6428666f726365292d666f7263652f320a090909656e640a09090972657475726e2073656c662e706f735f782d36342b73686b5f782c73686b5f790a0909656e642c0a0a09097368616b653d66756e6374696f6e2873656c662c20666f7263652c206475726174696f6e290a09090973656c662e7368616b655f666f7263652c2073656c662e7368616b655f72656d61696e696e67203d20666f7263652c206475726174696f6e0a0909656e640a097d0a0a0972657475726e20630a656e640a0a66756e6374696f6e20736176655f73636f726528290a09696620675f73636f72655f746f74616c203e3d20675f686967")
    (hex 35328 "685f73636f7265735b675f646966666963756c74795d5b315d207468656e0a0909675f686967685f73636f7265735b675f646966666963756c74795d5b315d2c20675f686967685f73636f7265735b675f646966666963756c74795d5b325d203d20675f73636f72655f746f74616c2c20675f796561720a09656e640a096c6f63616c20696e646578203d20310a09666f7220693d312c203820646f0a0909666f72206a3d312c3220646f0a0909096473657428696e6465782c20675f686967685f73636f7265735b695d5b6a5d290a090909696e646578202b3d20310a0909656e640a09656e640a656e640a0a66756e6374696f6e206c6576656c5f656e64")
    (hex 35584 "28290a0970312e72656164795f74696d652c20675f67616d655f73746174652c20675f7472616e736974696f6e5f74696d65203d203330302c20362c203135300a09675f73636f72655f746f74616c202b3d20675f73636f72655f6c6576656c0a656e640a0a66756e6374696f6e206c6576656c5f656e645f77696e28290a0969662070312e68705f637572203e2031207468656e0a090973636f72655f6164642870312c203235290a09656e640a09675f67616d655f7472616e736974696f6e5f746f5f7374617465203d20370a09736678283133290a20206c6576656c5f656e6428290a656e640a0a66756e6374696f6e206c6576656c5f656e645f6261")
    (hex 35840 "6428290a09675f67616d655f7472616e736974696f6e5f746f5f7374617465203d20380a09736678283132290a096c6576656c5f656e6428290a09736176655f73636f726528290a656e640a0a66756e6374696f6e206c6576656c5f656e645f76696c6c616765725f64696564286b696c6c65645f62795f706c61796572290a09696620675f646966666963756c7479203c2037207468656e0a090972657475726e0a09656e640a09675f6c6576656c5f656e645f726561736f6e203d20226c657420612076696c6c6167657220646965220a096966206b696c6c65645f62795f706c61796572207468656e0a0909675f6c6576656c5f656e645f726561736f")
    (hex 36096 "6e203d20226b696c6c656420612076696c6c61676572220a09656e640a096c6576656c5f656e645f62616428290a656e640a0a66756e6374696f6e206c6576656c5f656e645f706c617965725f64696564286b696c6c65645f62795f6f62737461636c65290a2020675f6c6576656c5f656e645f726561736f6e203d2022736c61696e20696e20636f6d626174220a096966206b696c6c65645f62795f6f62737461636c65207468656e0a0909675f6c6576656c5f656e645f726561736f6e203d20227374756d626c656420696e746f206465617468220a09656e640a096c6576656c5f656e645f62616428290a656e640a0a66756e6374696f6e206d5f7370")
    (hex 36352 "6c617428782c20792c2073697a655f626173652c2073697a655f766172290a096c6f63616c2073203d0a097b0a0909783d782c0a0909793d792c0a090973697a653d66726e64612873697a655f7661722c2073697a655f62617365292c0a0a0909647261773d66756e6374696f6e2873656c662c20636f6c6f72290a090909696620636f6c6f72203d3d2030207468656e0a090909096369726366696c6c2873656c662e782c2073656c662e792c2073656c662e73697a652b312c20636f6c6f72290a090909656c73650a090909096369726366696c6c2873656c662e782c2073656c662e792c2073656c662e73697a652c20636f6c6f72290a090909656e64")
    (hex 36608 "0a0909656e642c0a097d0a0972657475726e20730a656e640a0a66756e6374696f6e206d5f7472616e736974696f6e5f73706c617474657228290a096c6f63616c2074203d0a097b0a09096c6973745f73706c6174733d7b7d2c0a0a0909696e69743d66756e6374696f6e2873656c66290a0909096c6f63616c20776970655f706f736974696f6e203d20300a0909097768696c6520776970655f706f736974696f6e203c2031323820646f0a0a09090909776970655f706f736974696f6e202b3d2031300a0a090909096164642873656c662e6c6973745f73706c6174732c206d5f73706c617428776970655f706f736974696f6e2b322d726e642834292c")
    (hex 36864 "2034382d66726e642836292c2031302c203829290a090909096164642873656c662e6c6973745f73706c6174732c206d5f73706c617428776970655f706f736974696f6e2b322d726e642834292c2066726e646128362c203830292c2031302c203829290a0a0909090969662072616e64632829207468656e0a09090909096164642873656c662e6c6973745f73706c6174732c206d5f73706c617428776970655f706f736974696f6e2b342d726e642838292c2033302d66726e64283135292c20322c203529290a09090909656e640a0a0909090969662072616e64632829207468656e0a09090909096164642873656c662e6c6973745f73706c6174732c")
    (hex 37120 "206d5f73706c617428776970655f706f736974696f6e2b342d726e642838292c2066726e64612831352c3938292c20322c203529290a09090909656e640a090909656e640a0909656e642c0a0a0909647261773d66756e6374696f6e2873656c66290a0909097265637466696c6c28302c2034312c203132382c2038372c2030290a0a090909666f72207320696e20616c6c2873656c662e6c6973745f73706c6174732920646f0a09090909733a647261772830290a090909656e640a0909097265637466696c6c28302c2034322c203132382c2038362c2038290a0a090909666f72207320696e20616c6c2873656c662e6c6973745f73706c617473292064")
    (hex 37376 "6f0a09090909733a647261772838290a090909656e640a0a0909656e642c0a097d0a09743a696e697428290a0972657475726e20740a656e640a0a66756e6374696f6e2069735f6c6576656c5f61637469766528290a09696620675f67616d655f7374617465203d3d2035206f7220675f67616d655f7374617465203d3d2036207468656e0a090972657475726e20747275650a09656e640a0a0972657475726e2066616c73650a656e640a0a66756e6374696f6e207570646174655f7765617468657228290a092d2d2d5b5b0a09696620675f776561746865725f706172745f72617465203d3d2030207468656e0a090972657475726e0a09656e640a0969")
    (hex 37632 "6620675f7469636b73202520675f776561746865725f706172745f72617465203d3d2030207468656e0a0a09096c6f63616c20706172745f7370726974652c20706172745f636f6c6f722c20646f75626c655f72617465203d20675f776561746865725f7370726974652c20675f776561746865725f636f6c6f722c20300a0a0909696620675f736561736f6e203d3d2030207468656e0a090909646f75626c655f72617465203d20310a0909656c7365696620675f736561736f6e203d3d2033207468656e0a090909706172745f737072697465202b3d2066726e642832290a0909096966206e6f7420675f6c6576656c5f6e69676874207468656e0a0909")
    (hex 37888 "0909706172745f636f6c6f72202b3d2066726e642832290a090909656e640a0909656e640a0a0909666f7220693d302c646f75626c655f7261746520646f0a0909096c6f63616c2070203d206d5f706172745f73707269746528706172745f7370726974652c2066726e6428323536292d3132382c202d382c20675f776561746865725f66616c6c5f726174652c20706172745f636f6c6f722c20706172745f636f6c6f722c203330302c2066616c73652c2074727565290a090909696620675f736561736f6e203d3d2030207468656e0a09090909702e64782c09702e73706c6173685f6c6f63203d202e332b726e64282e31292c2066726e646128313238")
    (hex 38144 "2c203136290a09090909702e7570646174653d66756e6374696f6e2873656c66290a090909090969662073656c662e79203e3d2073656c662e73706c6173685f6c6f63207468656e0a090909090909666f7220693d302c3120646f0a090909090909096c6f63616c2073203d206d5f706172745f737072697465283130332c2073656c662e782c2073656c662e792c202d726e642831292c2031322c2031322c20352c2066616c73652c2074727565290a09090909090909732e6464792c20732e6478203d202e312c20726e64282e35290a0909090909090969662072616e646328353029207468656e0a0909090909090909732e6478203d202d726e64282e")
    (hex 38400 "35290a09090909090909656e640a090909090909656e640a09090909090964656c286c6973745f70617274735f66726f6e742c2073656c66290a0909090909656e640a090909090973656c663a7570646174655f6261736528290a09090909656e640a090909656c73650a09090909702e7570646174653d66756e6374696f6e2873656c66290a090909090969662073656c662e79203e20313238207468656e0a09090909090964656c286c6973745f70617274735f66726f6e742c2073656c66290a09090909090972657475726e0a0909090909656e640a090909090969662072616e646328323529207468656e0a0909090909096c6f63616c2077736869")
    (hex 38656 "6674203d20675f776561746865725f77696e645f73686966740a09090909090969662072616e646328353029207468656e0a09090909090909777368696674203d202d675f776561746865725f77696e645f73686966740a090909090909656e640a09090909090973656c662e6478202b3d207773686966740a0909090909656e640a090909090973656c662e6478203d206d6964282d312c2073656c662e64782c2031290a090909090973656c663a7570646174655f6261736528290a09090909656e640a090909656e640a0909656e640a09656e640a092d2d5d5d0a656e640a0a66756e6374696f6e205f757064617465363028290a09675f7469636b73")
    (hex 38912 "202b3d20310a092d2d5b5b0a0969662073746174283929203c2073746174283829207468656e0a092d2d097072696e7468282264726f70706564206672616d6520222e2e675f7469636b73290a09656e640a2d2d5d5d0a0963616d3a75706461746528290a096c6f63616c206675203d2066756e6374696f6e28692920693a757064617465282920656e640a0a09696620675f67616d655f7374617465203d3d2036207468656e0a0909675f7472616e736974696f6e5f74696d65202d3d20310a0909696620675f7472616e736974696f6e5f74696d65203c3d2030207468656e0a09090963616d3a7368616b6528332c203230290a090909675f67616d655f")
    (hex 39168 "7374617465203d20675f67616d655f7472616e736974696f6e5f746f5f73746174650a0909097366782839290a0909656e640a0909696620675f7469636b7320252032203d3d2030207468656e0a09090972657475726e0a0909656e640a09656e640a0a09696620675f67616d655f7374617465203d3d2034207468656e0a0909675f7472616e736974696f6e5f74696d65202d3d20310a0909696620675f7472616e736974696f6e5f74696d65203c3d2030207468656e0a090909675f67616d655f7374617465203d20350a0909656e640a09656e640a0a09666f7265616368286c6973745f70617274735f626c6f6f642c206675290a09666f7265616368")
    (hex 39424 "286c6973745f70617274735f6261636b2c206675290a09666f7265616368286c6973745f70617274735f66726f6e742c206675290a0a09696620675f67616d655f7374617465203e203320616e6420675f67616d655f7374617465203c2039207468656e0a090969662067616d655f70617573655f74696d6572203e2030207468656e0a09090967616d655f70617573655f74696d6572202d3d20310a09090972657475726e0a0909656e640a0a09097570646174655f7765617468657228290a0909696620675f706c617965725f64616d616765645f74696d65203e2030207468656e0a090909675f706c617965725f64616d616765645f74696d65202d3d")
    (hex 39680 "20310a0909656e640a0909696620675f67616d655f7374617465203e2034207468656e0a090909696620675f7469636b732025203235203d3d203020616e642028236c6973745f656e656d696573202b20236c6973745f76696c6c616765727329203c20675f6c6576656c5f70656f706c655f73637265656e5f6d6178207468656e0a0909090969662072616e64632838352920616e6420675f6c6576656c5f656e656d6965735f636f756e74203e2030207468656e0a0909090920096d5f656e656d795f72616e646f6d28290a09090909656c73650a0909090909696620675f6c6576656c5f76696c6c61676572735f636f756e74203e2030207468656e0a")
    (hex 39936 "090909090909675f6c6576656c5f76696c6c61676572735f636f756e74202d3d20310a0909090909096d5f656e656d795f76696c6c61676572286765745f67656e5f636f6f7264732829290a0909090909656c7365696620675f6c6576656c5f656e656d6965735f636f756e74203e2030207468656e0a0909090909096d5f656e656d795f72616e646f6d28290a0909090909656e640a09090909656e640a090909656e640a0909656e640a0a090970313a75706461746528290a0a0909666f7265616368286c6973745f68656164732c206675290a0909666f72206520696e20616c6c286c6973745f70656f706c652920646f0a0920202020653a75706461")
    (hex 40192 "746528290a0909092d2d206f6e6c7920616c6c6f772064616d61676520616e6420696d706163747320696620776527726520696e207468652067616d652070726f70657220286e6f7420696e207472616e736974696f6e290a090909696620675f67616d655f7374617465203d3d2035207468656e0a09090909696620696e745f636f6c732870312c20652c203229207468656e0a090909090969662070312e69735f736c617368696e6720616e64206e6f742070312e736c6173685f6861735f696d706163746564207468656e0a090909090909696620652e69735f76696c6c61676572206f7220286e6f7420652e69735f6675726e697475726520616e64")
    (hex 40448 "20236c6973745f656e656d696573203d3d203120616e6420675f6c6576656c5f656e656d6965735f636f756e74203d3d203029207468656e0a090909090909096d5f706172745f696d706163742865290a09090909090909653a6b696c6c2870312c2066616c73652c2070312e736c6173685f616e676c652c206e6f7420652e69735f76696c6c61676572290a090909090909656c73650a09090909090909696620652e61747461636b5f74696d655f72656d203e2030207468656e0a09090909090909096966206e6f7420617474656d70745f6465666c6563745f746172676574286529207468656e0a090909090909090909736c6173685f746172676574")
    (hex 40704 "2865290a0909090909090909656e640a09090909090909656c73650a0909090909090909736c6173685f7461726765742865290a09090909090909656e640a090909090909656e640a090909090909627265616b0a0909090909656e640a09090909096966206e6f742070312e69735f736c617368696e6720616e64206e6f7420652e69735f666c79696e6720616e6420696e745f636f6c732870312c206529207468656e0a0909090909096966206e6f7420653a746f7563685f636c6173732829207468656e202d2d20696620616e20656e656d79206120636c61737320646f65736e27742068616e646c6520746f75636820756e697175656c792c20646f")
    (hex 40960 "2064616d616765207768656e20746f756368696e670a09090909090909696620652e61747461636b5f74696d655f72656d203e2030206f7220675f646966666963756c7479203e2032207468656e0a090909090909090970313a64616d6167652865290a09090909090909656e640a090909090909656e640a09090920202020656e640a09090909656e640a0a09090909696620652e61747461636b5f74696d655f72656d203e2030207468656e0a0909090909666f72207620696e20616c6c286c6973745f76696c6c61676572732920646f0a0909090909096966206e6f7420762e69735f666c79696e6720616e6420696e745f636f6c7328652c20762920")
    (hex 41216 "7468656e0a09090909090909763a6b696c6c28652c2066616c73652c20652e616e676c65290a090909090909656e640a0909090909656e640a09090909656e640a09090909696620652e69735f666c79696e67207468656e0a0909090909666f7265616368286c6973745f6f626a656374732c2066756e6374696f6e286f290a0909090909096966206f2e69735f646561646c7920616e64206f2e69735f73746174696320616e64206e6f7420652e69735f686561767920616e64206e6f7420652e69735f61726d6f72656420616e6420696e745f636f6c7328652c206f2c203229207468656e0a0909090909090968616e646c655f696d706163745f646561")
    (hex 41472 "746828652c206f290a09090909090909736678283235290a090909090909096966206e6f7420652e69735f6675726e6974757265207468656e0a09090909090909096f3a6465616c745f64616d61676528290a09090909090909656e640a090909090909656e640a0909090909656e64290a09090909656e640a090909656e640a092020656e640a0a0909696620675f67616d655f7374617465203d3d2035207468656e0a09090969662069735f74696d65645f6d6f64652829207468656e0a09090909675f727573686d6f64655f7469636b73202d3d20310a09090909696620675f727573686d6f64655f7469636b732025203630203d3d203020616e6420")
    (hex 41728 "675f727573686d6f64655f7469636b73203c20343230207468656e0a0909090909736678283136290a09090909656e640a09090909696620675f727573686d6f64655f7469636b73203c203630207468656e0a090909090970313a64616d6167652870312c2074727565290a0909090909675f6c6576656c5f656e645f726561736f6e203d202272616e206f7574206f662074696d65220a09090909096c6576656c5f656e645f62616428290a090909090972657475726e0a09090909656e640a090909656e640a090909666f7265616368286c6973745f6f626a656374732c2066756e6374696f6e286f290a090909096f3a75706461746528290a09090909")
    (hex 41984 "696620696e745f636f6c73286f2c20703129207468656e0a09090909096966206f2e69735f646561646c79207468656e0a09090909090970313a64616d616765286f290a0909090909096f3a6465616c745f64616d61676528290a0909090909656c73650a0909090909096f3a65617428290a0909090909656e640a09090909656e640a090909656e64290a0909656e640a09656e640a092d2d5b5b0a09696620675f67616d655f7374617465203d3d2035207468656e0a090969662062746e70283529207468656e0a0909097472616e736974696f6e5f6c6576656c28290a0909656e640a09656e640a092d2d5d5d0a09696620675f67616d655f73746174")
    (hex 42240 "65203e2036207468656e0a0909696620675f7469636b7320252035203d3d2030207468656e0a0909096c6f63616c2070203d206d5f706172745f7370726974652838362c2066726e6461283131382c3130292c2034362b66726e64283336292c20302c20372c2031332c2066726e646128352c3130292c2066616c73652c2066616c7365290a090909702e6478203d202d310a0909656e640a090969662062746e70283429207468656e0a090909696620675f67616d655f7374617465203d3d2037207468656e0a090909097472616e736974696f6e5f6c6576656c28290a090909656c73650a0909090972657365745f67616d6528290a090909656e640a09")
    (hex 42496 "09656e640a09656c7365696620675f67616d655f7374617465203d3d2030207468656e0a090969662062746e70283429207468656e0a0909097366782830290a090909736678283131290a090909675f67616d655f7374617465203d20340a2d2d5b5b0a090909666f7220693d312c323320646f0a090909097472616e736974696f6e5f6c6576656c28290a090909656e640a0909092d2d5d5d0a09090972657365745f6c6576656c28290a0909656e640a090969662062746e70283029207468656e0a090909675f646966666963756c7479202d3d20310a0909656c736569662062746e70283129207468656e0a090909675f646966666963756c7479202b")
    (hex 42752 "3d20310a0909656e640a0909675f646966666963756c7479203d207772617028675f646966666963756c74792c20312c2038290a09656e640a0969662062746e70283529207468656e0a0909696620675f67616d655f7374617465203c2034207468656e0a0909097366782830290a09090972657365745f6c6576656c28290a090909696620675f67616d655f7374617465203d3d2031207468656e0a090909096d5f666f6f642836382c3638290a090909096d5f656e656d795f76696c6c616765722836302c203638290a090909656c7365696620675f67616d655f7374617465203d3d2030207468656e0a090909097031203d206d5f706c617965722836")
    (hex 43008 "342c3339290a090909096d5f656e656d795f77616e6465722833332c203833290a090909096d5f656e656d795f7365656b65722834332c203833290a090909096d5f656e656d795f6172636865722835332c203833290a090909096d5f656e656d795f626f6d6265722836332c203833290a090909096d5f656e656d795f626f73732837332c203833290a090909096d5f6f626a6563742838332c2038332c207b3136302c3136317d2c2074727565290a090909096d5f6f626a6563742839332c2038332c207b3137362c3137377d2c2074727565290a0a090909096d5f656e656d795f76696c6c616765722836342c20313039290a090909656e640a090909")
    (hex 43264 "675f67616d655f7374617465203d207772617028675f67616d655f73746174652b312c20302c2033290a0909656e640a09656e640a656e640a0a66756e6374696f6e206c6576656c5f63726561746528290a097031203d206d5f706c617965722836342c3634290a0972656c6f6164283078323030302c203078323030302c2030783130303029202d2d2072656c6f6164206f726967696e616c206d617020646174610a0a096c6f63616c20636f6c6f725f63686f6963652c20626c6f636b5f73656c5f782c20626c6f636b5f73656c5f79203d20675f736561736f6e2c2066726e642832292c20300a0a09696620675f79656172207e3d20675f796561725f")
    (hex 43520 "656e6467616d65207468656e0a0909696620675f79656172207e3d2031207468656e0a09090969662072616e646328323529207468656e0a09090909675f6c6576656c5f696e646f6f722c20626c6f636b5f73656c5f79203d0a09090909747275652c20310a090909656e640a0a09090969662072616e646328323529207468656e0a09090909675f6c6576656c5f6e69676874203d20747275650a090909656e640a0a0909096966206e6f7420675f6c6576656c5f696e646f6f72207468656e0a0909090969662072616e646328323529207468656e0a0909090909675f776561746865725f7370726974652c0a0909090909675f776561746865725f636f")
    (hex 43776 "6c6f722c0a0909090909675f776561746865725f706172745f726174652c0a0909090909675f776561746865725f77696e645f73686966742c0a0909090909675f776561746865725f66616c6c5f72617465203d0a0909090909675f776561746865725f736561736f6e646174615b675f736561736f6e2a352b315d2c0a0909090909675f776561746865725f736561736f6e646174615b675f736561736f6e2a352b325d2c0a0909090909675f776561746865725f736561736f6e646174615b675f736561736f6e2a352b335d2c0a0909090909675f776561746865725f736561736f6e646174615b675f736561736f6e2a352b345d2c0a0909090909675f")
    (hex 44032 "776561746865725f736561736f6e646174615b675f736561736f6e2a352b355d0a0a0909090909696620675f6c6576656c5f6e6967687420616e6420675f736561736f6e207e3d2030207468656e0a090909090909675f776561746865725f636f6c6f72203d20310a0909090909656e640a09090909656e640a090909656e640a0909656e640a09656c73650a0909626c6f636b5f73656c5f78203d20320a09656e640a0a09696620626c6f636b5f73656c5f79203d3d2030207468656e0a0909675f6c6576656c5f70656f706c655f73637265656e5f6d61782c20675f6c6576656c5f73637265656e5f627566666572203d20372b312a675f796561722c20")
    (hex 44288 "300a09656e640a0a09696620675f6c6576656c5f696e646f6f72207468656e0a0909636f6c6f725f63686f696365203d20360a09656e640a09696620675f6c6576656c5f6e69676874207468656e0a0909636f6c6f725f63686f696365203d20340a0909696620675f6c6576656c5f696e646f6f72207468656e0a090909636f6c6f725f63686f696365203d20350a0909656e640a09656e640a0a096c6f63616c20636f6c6f72735f737472696e67203d202230332c31312c30352c30302c30372c30322c31312c30392c31302c30352c30302c30372c30342c30342c30342c30392c30352c30302c30372c30322c31302c30372c30362c30352c30302c3035")
    (hex 44544 "2c30362c30302c30302c30312c30352c30302c30372c30322c31322c30302c30312c30342c30302c30372c30322c30372c30302c30322c30392c30302c30372c30312c3037220a09092d2d2020202020202020202020202020202020202020202020202020202020202020202020202020207c20202020202020202020202020202020202020207c20202020202020202020202020202020202020207c20202020202020202020202020202020202020207c20202020202020202020202020202020202020207c20202020202020202020202020202020202020207c20202020202020202020202020202020202020207c0a09092d2d09090909090909090973")
    (hex 44800 "7072696e67090909090909092073756d6d6572090909090909090966616c6c09090909090909092077696e74657209090909090909096e69676874090909090909090920696e646f6f72206461726b0909090909696e646f6f72206c696768740a092d2d09090909090909090909636f6c6f725f67726f756e642c20636f6c6f725f64657461696c2c20636f6c6f725f77616c6c2c20636f6c6f725f6f75746c696e652c20636f6c6f725f696e746572666163652c20636f6c6f725f626c6f6f645f6275726e2c20636f6c6f725f7469746c655f746578740a0a096c6f63616c20636c2c206f6666736574203d2073706c697428636f6c6f72735f737472696e")
    (hex 45056 "67292c20636f6c6f725f63686f6963652a370a0a09675f636f6c6f725f67726f756e642c20675f636f6c6f725f64657461696c2c20675f636f6c6f725f77616c6c2c20675f636f6c6f725f6f75746c696e652c20675f636f6c6f725f696e746572666163652c20675f636f6c6f725f626c6f6f645f6275726e2c20675f636f6c6f725f7469746c655f74657874203d0a09636c5b312b6f66667365745d2c20636c5b322b6f66667365745d2c20636c5b332b6f66667365745d2c20636c5b342b6f66667365745d2c20636c5b352b6f66667365745d2c20636c5b362b6f66667365745d2c20636c5b372b6f66667365745d0a0a096c6f63616c207265706c6163")
    (hex 45312 "655f776569676874732c206861735f706c616365645f666f6f64203d2073706c6974282236352c38312c39372c3136302c3137362c39393922292c2066616c73650a09666f7220793d302c20313520646f0a0909666f7220783d302c20313520646f0a0909096c6f63616c2074696c652c20737761707065645f74696c65203d206d67657428782b626c6f636b5f73656c5f782a31362c20792b626c6f636b5f73656c5f792a3136292c2066616c73650a09090969662074696c65203d3d20313630207468656e0a0909090969662072616e64632829206f7220675f79656172203d3d20675f796561725f656e6467616d65207468656e0a09090909096c6f63")
    (hex 45568 "616c20636f6f72645f782c20636f6f72645f792c2063686f73656e203d20782a382b342c20792a382b342c207265706c6163655f776569676874735b66726e646128237265706c6163655f77656967687473295d0a09090909092d2d2073746172742077697468206261736963207370696b652c207468656e20706f737369626c652061646420746f2067657420746865206f7468657220747970650a090909090969662063686f73656e203e20393938206f7220675f79656172203d3d20675f796561725f656e6467616d65207468656e0a0909090909096966206861735f706c616365645f666f6f64207468656e0a0909090909090964656c287265706c")
    (hex 45824 "6163655f776569676874732c20393939290a090909090909656e640a0909090909096861735f706c616365645f666f6f64203d20747275650a0909090909096d5f666f6f6428636f6f72645f782c20636f6f72645f79290a0909090909656c736569662063686f73656e203e203937207468656e0a0909090909096d5f6f626a65637428636f6f72645f782c20636f6f72645f792c207b63686f73656e2c2063686f73656e2b317d2c2074727565290a0909090909656c73650a090909090909696620675f6c6576656c5f696e646f6f72207468656e0a0909090909090963686f73656e202d3d20310a090909090909656e640a0909090909096d5f656e656d")
    (hex 46080 "795f6675726e697475726528636f6f72645f782c20636f6f72645f792c2063686f73656e2c2063686f73656e203e203831290a0909090909656e640a09090909656e640a09090909737761707065645f74696c65203d20747275650a090909656e640a090909696620737761707065645f74696c65207468656e0a09090909696620675f6c6576656c5f696e646f6f72207468656e0a09090909096d73657428782c20792c20313434290a09090909656c73650a09090909096d73657428782c20792c2030290a09090909656e640a090909656c73650a090909096d73657428782c20792c2074696c65290a090909656e640a0909656e640a09656e640a656e")
    (hex 46336 "640a0a66756e6374696f6e207472616e736974696f6e5f6c6576656c28290a0a09675f736561736f6e202b3d20310a09696620675f736561736f6e203e2033207468656e0a0909675f736561736f6e203d20300a0909675f79656172202b3d20310a0a0909696620675f79656172203d3d2037207468656e0a09090961646428675f656e656d795f776569676874732c2035290a0909656e640a0a0909666f7220693d312c203420646f0a090909696620675f796561722b31203e3d2069207468656e0a0909090961646428675f656e656d795f776569676874732c2069290a090909656e640a0909656e640a09656e640a0a0972657365745f6c6576656c28")
    (hex 46592 "290a09696620675f79656172203d3d20675f796561725f656e6467616d65207468656e0a0909675f67616d655f7374617465203d20390a0909736678283135290a090970312e79203d203130380a09096d5f656e656d795f76696c6c616765722833362c203234290a09096d5f656e656d795f76696c6c616765722839322c203234290a09096d5f656e656d795f76696c6c616765722835322c20313038290a09096d5f656e656d795f76696c6c616765722837362c20313038290a0909675f73636f72655f746f74616c202b3d20313030300a0909675f6c6576656c5f656e645f726561736f6e203d202272657475726e656420686f6d65220a0909736176")
    (hex 46848 "655f73636f726528290a09656c73650a0909736678283131290a0909675f67616d655f7374617465203d20340a09656e640a656e640a0a66756e6374696f6e2072657365745f6c6576656c28290a0963616d3d6d5f63616d28290a097461626c655f636c656172286c6973745f70617274735f6261636b290a097461626c655f636c656172286c6973745f70617274735f66726f6e74290a097461626c655f636c656172286c6973745f70617274735f626c6f6f64290a097461626c655f636c656172286c6973745f6865616473290a097461626c655f636c656172286c6973745f656e656d696573290a097461626c655f636c656172286c6973745f76696c")
    (hex 47104 "6c6167657273290a097461626c655f636c656172286c6973745f70656f706c65290a097461626c655f636c656172286c6973745f647261777374756666290a097461626c655f636c656172286c6973745f6f626a65637473290a097461626c655f636c656172286c6973745f7374657073290a0a09675f737061776e65645f626f73732c20675f727573686d6f64655f7469636b732c0a09675f7469636b732c20675f7472616e736974696f6e5f746f5f73746174652c20675f7472616e736974696f6e5f74696d652c0a09675f706c617965725f64616d616765645f74696d652c20675f6c6576656c5f73637265656e5f6275666665722c0a09675f6c6576")
    (hex 47360 "656c5f76696c6c61676572735f636f756e742c20675f6c6576656c5f656e656d6965735f636f756e742c20675f6c6576656c5f70656f706c655f73637265656e5f6d61782c0a09675f73636f72655f6c6576656c2c0a0967616d655f70617573655f74696d65722c0a09675f6c6576656c5f696e646f6f722c20675f6c6576656c5f6e696768742c0a09675f776561746865725f7370726974652c20675f776561746865725f636f6c6f722c20675f776561746865725f706172745f726174652c20675f776561746865725f77696e645f73686966742c20675f776561746865725f66616c6c5f72617465203d0a0966616c73652c20313230302b36302a675f")
    (hex 47616 "796561722c0a09302c20302c203135302c0a09302c2031362c0a09332b666c72282e352a675f79656172292c20372b332a675f796561722c20342b312a675f796561722c0a09302c0a09302c0a0966616c73652c2066616c73652c0a09302c20302c20302c20302c20300a0a09696620675f67616d655f7374617465203e2033207468656e0a09096c6576656c5f63726561746528290a09656e640a0a09636c7328675f636f6c6f725f67726f756e64290a0970616c28312c20675f636f6c6f725f64657461696c290a0970616c28322c2030290a0970616c28352c20675f636f6c6f725f77616c6c290a096d617028302c302c302c302c31362c3136290a09")
    (hex 47872 "70616c28290a09636f70795f73637265656e5f746f5f6d656d28290a0a097472616e736974696f6e5f73706c6174746572203d206d5f7472616e736974696f6e5f73706c617474657228290a656e640a0a66756e6374696f6e2072657365745f67616d6528290a20202d2d20696e697469616c697a6564207661726961626c65732c20627574206368616e676520647572696e672067616d650a09675f67616d655f73746174652c20675f6c6576656c5f656e645f726561736f6e2c0a09675f796561722c20675f736561736f6e2c0a09675f73636f72655f746f74616c2c0a09675f6c6576656c5f73637265656e5f6275666665722c20675f7469636b732c")
    (hex 48128 "0a09675f656e656d795f77656967687473203d0a09302c20226465666561746564207468652076616e64616c73222c0a09312c20302c0a09302c0a0931362c20302c0a0973706c69742822312c312c312c322c322c322c3222290a0a0972657365745f6c6576656c28290a0a202063616d3a7368616b6528332c203230290a097366782839290a656e640a0a0a66756e6374696f6e205f696e697428290a0963617274646174612822746d69726f626f745f62756e62756e73616d757261695f3422290a09675f616c7068616265745f737072697465732c0a09675f736561736f6e5f6e616d65732c0a09675f776561746865725f736561736f6e646174612c")
    (hex 48384 "0a09675f646966666963756c74795f737472696e67732c0a09675f646966666963756c74795f64657363732c0a09675f796561725f656e6467616d652c0a09675f646966666963756c7479203d0a0973706c69742822612c622c632c642c652c662c672c682c692c6a2c6b2c6c2c6d2c6e2c6f2c702c712c722c732c742c752c762c772c782c792c7a2c302c312c322c332c342c352c362c372c382c39222c20222c222c2066616c7365292c0a0973706c69742822737072696e672c73756d6d65722c66616c6c2c77696e7465722c3134302c3134322c3137322c31373422292c0a0973706c697428223131392c31322c312c302c332c3132312c31342c362c")
    (hex 48640 "2e30352c2e352c3132332c392c362c2e30352c2e352c3132312c362c312c2e312c3122292c0a0973706c69742822656173792c656173792c6e6f726d2c6e6f726d2c686172642c686172642c68656c6c2c68656c6c22292c0a0973706c69742822656e656d7920737472696b6573206465616c2064616d6167652c732c656e656d7920746f7563686573206465616c2064616d6167652c732c6865726f20646965732066726f6d20612073696e676c65206869742c732c76696c6c6167657220646561746820656e6473207468652067616d652c7322292c0a0931302c0a09330a0a096c6f63616c20696e646578203d20310a09675f686967685f73636f7265")
    (hex 48896 "73203d207b7d0a09666f7220693d312c3820646f0a0909675f686967685f73636f7265735b695d203d207b7d0a0909666f72206a3d312c3220646f0a090909675f686967685f73636f7265735b695d5b6a5d203d206467657428696e646578290a090909696e646578202b3d20310a0909656e640a09656e640a0972657365745f67616d6528290a656e640a0a2d2d20617272616e676520616c6c206974656d7320696e2061206c69737420627920746865697220792076616c75652c20287573656420666f722064726177696e67207468656d20696e206c617965726564206f72646572206f6e207468652073637265656e290a66756e6374696f6e20736f")
    (hex 49152 "72745f62795f79287429202d2d696e73657274696f6e20736f72742c20617363656e64696e6720790a2020666f72206e3d322c237420646f0a202020206c6f63616c20693d6e0a202020207768696c6520693e3120616e6420745b695d2e793c745b692d315d2e7920646f0a202020202020745b695d2c745b692d315d3d745b692d315d2c745b695d0a202020202020692d3d310a20202020656e640a2020656e640a656e640a0a66756e6374696f6e2069735f74696d65645f6d6f646528290a0972657475726e20675f646966666963756c747920252032203d3d20300a656e640a0a66756e6374696f6e205f6472617728290a0a09696620675f67616d65")
    (hex 49408 "5f7374617465203e203320616e6420675f67616d655f7374617465203c203130207468656e0a090970617374655f73637265656e5f66726f6d5f6d656d2028290a0a0909666f72206120696e20616c6c286c6973745f70617274735f626c6f6f642920646f0a090909696620612e74696d65203d3d20612e6475726174696f6e207468656e0a09090909613a6472617728290a090909656e640a0909656e640a0a09092d2d206472617720736e6f772073746570730a0909666f72206120696e20616c6c20286c6973745f73746570732920646f0a09090970616c28372c20675f636f6c6f725f64657461696c290a0909097370722838372b66726e64283229")
    (hex 49664 "2c20612e782c20612e79290a09090970616c28290a09090964656c286c6973745f73746570732c2061290a0909656e640a0a0909636f70795f73637265656e5f746f5f6d656d28290a0a0909696620675f706c617965725f64616d616765645f74696d65203e2030207468656e0a090909636c732838290a0909656e640a0909696620675f67616d655f7374617465203d3d2039207468656e0a0909097265637466696c6c28302c34302c3132382c38382c3132290a0909656e640a0a09096c6f63616c206664203d2066756e6374696f6e28692920693a64726177282920656e640a0a09092d2d20736f727420746865206c697374206f66206f6273746163")
    (hex 49920 "6c657320616e64206163746f7273206279207468656972207920636f6f7264696e61746520736f2077652063616e207468656e2064726177207468656d20696e202273637265656e206f726465722220666f7220636f7272656374206f7665726c617070696e670a0909736f72745f62795f79286c6973745f647261777374756666290a0909666f7265616368286c6973745f70617274735f626c6f6f642c206664290a0909666f7265616368286c6973745f70617274735f6261636b2c206664290a0909666f7265616368286c6973745f6472617773747566662c206664290a0909666f7265616368286c6973745f70617274735f66726f6e742c20666429")
    (hex 50176 "0a0a0909696620675f67616d655f7374617465203d3d2034207468656e0a0909096c6f63616c20736561736f6e5f737072697465203d20675f736561736f6e5f6e616d65735b352b675f736561736f6e5d0a090909696620675f6c6576656c5f6e69676874207468656e0a09090909736561736f6e5f737072697465203d203130310a090909656e640a09090973707228736561736f6e5f7370726974652c2035362c2032362c20322c2032290a09090973707228736561736f6e5f7370726974652c2035362c2038342c20322c2032290a0909097072696e7473707269746528675f736561736f6e5f6e616d65735b675f736561736f6e2b315d2c2034382c")
    (hex 50432 "20675f636f6c6f725f7469746c655f74657874290a0909097072696e7473707269746528227965617220222e2e675f796561722c2037302c20675f636f6c6f725f7469746c655f74657874290a0909656e640a090969662069735f6c6576656c5f616374697665282920616e642069735f74696d65645f6d6f64652829207468656e0a0909097072696e74635f6f2822222e2e666c7228675f727573686d6f64655f7469636b732f3630292c20332c20372c20675f636f6c6f725f6f75746c696e65290a0909656e640a0a09656c73650a0909636c732830290a09656e640a0a097265637428302c302c3132372c3132372c31290a0a09696620675f67616d65")
    (hex 50688 "5f7374617465203e203020616e6420675f67616d655f7374617465203c2034207468656e0a0909696620675f67616d655f7374617465203d3d2031207468656e0a0909097072696e742822746865205c66636865726f5c66642c207765617279206f66206669676874696e6720696e5c6e2020202020656e646c65737320776172732c2077616e646572735c6e2074686520636f756e747279736964652c207365656b696e67207468655c6e2076696c6c616765206865206f6e63652063616c6c656420686f6d652e5c6e5c6e5c6e5c6e20206f6e20686973206a6f75726e65792c2068652066696e647320615c6e2020206e6174696f6e206f76657272756e")
    (hex 50944 "2062792066696c7468795c6e202020205c666362616e646974735c66642c2076756c676172205c6663726f6e696e5c66642c5c6e20202020616e642064616e6765726f7573205c666368617a617264735c66642e5c6e5c6e5c6e5c6e776865726576657220686520726f616d732c2068652070726f74656374735c6e20202020746865205c66637765616b5c666420616e64205c666368656c706c6573735c66642e222c342c362c3133290a0909656c7365696620675f67616d655f7374617465203d3d2032207468656e0a0909097072696e74282220207072657373205c66635c313432205c6664746f20737472696b6520656e656d6965732c5c6e202020")
    (hex 51200 "6b696c6c696e67207468656d2069662074686579206172655c6e206b6e6f636b656420696e746f20616e6f74686572205c66636f626a6563745c66642e5c6e5c6e206275696c64205c6663636f6d626f20636861696e735c6664206f6620696d70616374735c6e20202020202020666f72206d6f7265205c666370726573746967655c66642e5c6e5c6e202073617665205c666376696c6c61676572735c6664206f7220656174205c6663666f6f645c66645c6e20202020202020746f206761696e205c666370726573746967655c66642e5c6e5c6e5c6e5c6e20202020666f6f6420616c736f206865616c73205c6663776f756e64735c66642e5c6e5c6e20")
    (hex 51456 "20202066696e697368206120736561736f6e2061742066756c6c5c6e202020206865616c746820696e206f7264657220746f206561726e5c6e20202020202020205c6663626f6e75732070726573746967655c66642e222c342c362c3133290a0909656c7365696620675f67616d655f7374617465203d3d2033207468656e0a0909097072696e74632822646966666963756c7479206c6576656c73222c20362c2037290a0909092d2d2d5b5b0a090909666f7220693d312c382c3220646f0a090909096c6f63616c206932342c2073636f7265737472696e67203d20692a31322c2022220a090909097072696e746328675f646966666963756c74795f7374")
    (hex 51712 "72696e67735b695d2c20362b6932342c2039290a090909097072696e746328675f646966666963756c74795f64657363735b695d2c2031342b6932342c203132290a0a09090909666f72206a3d302c3120646f0a09090909096c6f63616c20656e64796561722c2079656172737472203d20675f686967685f73636f7265735b692b6a5d5b325d2c2022686f6d65220a0909090909696620656e6479656172207e3d20675f796561725f656e6467616d65207468656e0a09090909090979656172737472203d20227965617220222e2e656e64796561720a0909090909656e640a090909090973636f7265737472696e67203d2073636f7265737472696e672e")
    (hex 51968 "2e22222e2e28675f686967685f73636f7265735b692b6a5d5b315d2a3130292e2e2220222e2e796561727374720a09090909096966206a203d3d2030207468656e0a09090909090973636f7265737472696e67203d2073636f7265737472696e672e2e22202d20220a0909090909656e640a09090909656e640a090909097072696e74632873636f7265737472696e672c2032322b6932342c203133290a090909656e640a0909092d2d5d5d0a0909656e640a09097072696e746328225c313531206e657874222c203131372c20372c203632290a0909666f72206920696e20616c6c286c6973745f6472617773747566662920646f0a090909693a64726177")
    (hex 52224 "28290a0909656e640a090972657475726e0a09656e640a0a09696620675f67616d655f7374617465203e2036207468656e0a0909696620675f67616d655f7374617465203c2039207468656e0a0909097472616e736974696f6e5f73706c61747465723a6472617728290a0909656e640a09097072696e74635f6f28227965617220222e2e675f796561722e2e22207c20222e2e675f736561736f6e5f6e616d65735b675f736561736f6e2b315d2e2e22207c20222e2e675f646966666963756c74795f737472696e67735b675f646966666963756c74795d2c2035342c2039290a09097072696e74635f6f28675f6c6576656c5f656e645f726561736f6e2c")
    (hex 52480 "2034362c203130290a0920097072696e74635f6f282270726573746967653a20222e2e28675f73636f72655f746f74616c2a3130292e2e22222c2036322c2039290a0909696620675f73636f72655f746f74616c203e3d20675f686967685f73636f7265735b675f646966666963756c74795d5b315d207468656e0a0909097072696e74635f6f2822286e6577207265636f726429222c2037302c203130290a0909656e640a09097072696e74635f6f28227072657373205c31343220746f20636f6e74696e7565222c2037382c20372c20322c203632290a09656c7365696620675f67616d655f7374617465203d3d2030207468656e0a09097472616e7369")
    (hex 52736 "74696f6e5f73706c61747465723a6472617728290a09097072696e74737072697465282262756e2062756e222c2034342c2037290a09097072696e74632822732061206d2075207220612069222c2035342c203130290a09097072696e7463282276312e3361222c2036312c2032290a09096c696e652831302c2037302c203131382c2037302c2032290a09097072696e74635f6f28225c31343220706c6179207c205c31333920222e2e675f646966666963756c74795f737472696e67735b675f646966666963756c74795d2e2e22205c313435207c205c31353120696e666f222c2037362c20372c20322c203536290a090969662069735f74696d65645f")
    (hex 52992 "6d6f64652829207468656e0a0909097072696e74635f6f28222872757368206d6f646529222c2038342c2037290a0909656e640a09656e640a656e640a5f5f6766785f5f0a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303230303230303030303030303030303030303030303030303030303030303030303030303030303030303030303032363637373737323236363737373732323636373737373232363637373737320a30303030303030303030323032303030303030303030303030303030303030303030303030303030303232303232303030323832323832303030")
    (hex 53248 "303030303030303030303030303030303030303030303030303030303030303030303030303030323237323732303032323237373230303232373232373230323232323237320a30303730303730303032343234323030303032303230303030303030303030303032323032323030326464326464323030323864643832303030323032303030303030303030303030303030303030303030303030303030303030303030303030303032303230303030303032323030303030323030323030303030303032300a3030303737303030303234323432303030323432343230303032323232323030323434323434323032646432646432303032646464643230")
    (hex 53504 "3032363236323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303037373030303238383838383230323939393939323032616161616132303238383838383230326565656565323030323161316164323032363236323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303037303037303030323463346332303032343834383230303235633563323030323461346132303032646164616432303264646464")
    (hex 53760 "64323032363636363230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303032373737373230303239393939323030326161393932303032383838343432303265656564643230326464646432303032366236623230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303232363637323030323236363932303032323636353230303232383838323230323265656532323030323636")
    (hex 54016 "646432303032363636363230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303230303030303030303030303030303232323232303030303030303030303030303030303030303030303030303030303030303030303030303030303030303237373737323030323737373732303032373737373230303237373737320a3030303030303030303032323232323030303232323232303030323232323230303032363230303030323230323230303032")
    (hex 54272 "3636363636323030303030303030303030303030303030303030303030303030303030303030303030303030303030303237323732303030303237373230303032373232373230303032323237320a30303030303030303032363636363632303236363636363230323636363636323030303237323030326464326464323030323864643864323030323032303030303032303230303030303030303030303030303030303030303030303030303030303032303230303030303032323030303030323030323030303030303032300a303030303030303030323432373237323032343239323932303232326132613230303235353532303264643264643230")
    (hex 54528 "30326464646432303032363236323030303236323632303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303238383838383230323939393939323032616161616132303032353535353532326565656565323030323161316164323032363236323030303236323632303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303032346334633230303234383438323030323563356332303032353535353532303264616461")
    (hex 54784 "643230326464646464323032363636363230303236623662323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303032373737373230303239393939323030326161393932303032353535353532303265656564643230326464646432303236366236623632303236363136323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303237373732323030323939393230303032616161323030303032353535323032326565")
    (hex 55040 "6532323030326464646432303032363631363230323636363136363230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303230303230303030303030303030303030303030303030303030323030303030303030303030303030303030303030303030303030303030323737373732303237373636363230323737363637320a303030303030303030303230323030303030303030303030303030303030303030303030303030303032")
    (hex 55296 "32303232303030323832323832303030303030303030303030303030303030303032373230303030323232323030303030303030303030303030303030303032373232323732323732323237323030303232373232300a30303030303030303032343234323030303032303230303030303030303030303030303030303030326464326464323030323864643832303030303030303030303230303030303030303032373230303032363638363230303030303030303030303030303030303030323030303230303230303032303030303030323030300a30303030303030303032343234323030303234323432303030323232323230303030303030303030")
    (hex 55552 "326464326464323030326464646432303030303030303030323832323232323030303032373230303030323636383230303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303238383838383230323939393939323032616161616132303030303030303030326565656565323030323161316164323030303030303030303237373737373230303032373230303030323638383230303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303234633463323030323438343832303032356335633230303030303030")
    (hex 55808 "3030303264616461643230326464646464323030303030303030323832323232323030303032373230303032363636383230303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303032373737373230303239393939323030326161393932303030303030303030303265656564643230326464646432303030303030303030303230303030303030303238323832303030323232323030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030323737373232303032393939323230303261616132323030303030")
    (hex 56064 "30303030323265656532323030326464646432303030303030303030303030303030303030303032303230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030646464646430303030303030303030303030303030303030303030303030303030303030303030303230303230303030303030303030303032303230303030303030303030303030303030303030303030303030303030323230323230303030323030323030303032303230303030323737373737320a30303030303030303030303037303730303030303030303030303030303030303030")
    (hex 56320 "303030303030303232303232303030323832323832303030303030303030303234323432303030303230323030303030303030303030303232303232303032646432646432303032383232383230303236323632303030303237323232300a30303030303030303037373737373030303032303230303030303030303030303030303030303030326464326464323030323864643832303030323032303030303234323432303030323432343230303032323232323030323434323434323032646432646432303032386464383230303236323632303030303032303030300a3030303030303030303037613761303030323432343230303032323232323030")
    (hex 56576 "3030303030303030326464326464323030326464646432303032363236323030323838383838323032393939393932303261616161613230323838383838323032656565656532303032646464643230303236363636323030303030303030300a30303030303030303030373737373030323939393939323032616161616132303030303030303030326565656565323030323161316164323032363236323030303234633463323030323438343832303032356335633230303234613461323030326461646164323032316131616432303236623662323030303030303030300a303030303030303030303737373030303032343834383230303235633563")
    (hex 56832 "32303030303030303030303264616461643230326464646464323032366236623230303237373737323030323939393932303032616139393230303238383834343230326565656464323032646464646432303236363136323030303030303030300a30303030303030303037373737373030303239393939323030326161393932303030303030303030303265656564643230326464646432303032363631363230303032323232303030303232323230303030323232323030303032323232323030303232323232303030323232323230303032323232303030303030303030300a30303030303030303030303030373030303239393936363230326161")
    (hex 57088 "613636323030303030303030323265656532323030326464643636323236363631363632303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303032323030303030323232323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030323434323030303234343434323030303030303030303030")
    (hex 57344 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30323434343432303032393434343432303030303030303030303030303030303030303030303030303030303030303030303030303030303030303730303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303235343435323032393434343434323030303030303030")
    (hex 57600 "30303030303030303030303030303030303030303030303030303037303030303030303730303030303037303730303030303737373030303030373737303030303030303030303030303030303030303030303030303232323030303030303030303030303030300a30323435353432303234343434343432303030303030303030303030303030303030303030303030303030303030303030303037303030303030303730303030303737373737303030373030373030303037373737373030303030303030303030303030303030303030303030323535353230303030303030303030303030300a30323432323432303235343434343532303030303030")
    (hex 57856 "303030303030303030303030303030303030303030303030303030303037303030303030303030303030303037303730303030373037373030303037303730373030303030303030303030303030303030303030303030323535353230303030303030303030303030300a30323432323432303235353535353532303030303030303030303030303030303030303030303030303030303030303030303030303030303030303730303030303737373737303030373030303030303037373737373030303030303030303030303030303030303030303030323535353230303030303030303030303030300a3030323030323030303232323232323030303030")
    (hex 58112 "3030303030303030303030303030303030303030303030303030303030303037303030303030303030303030303037303730303030303737373030303030373037303030303030303030303030303030303030303030303030323535353230303030303030303030303030300a30303032323030303030303030303030303030303230303030303030323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303032353534353532303030303030303030303030300a303032636332303030323232323232303030")
    (hex 58368 "32323432303030303232343230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303235353434343535323030303030303030303030300a30326332326332303234343434343432303239343439323030323362623332303030303030303030303030303030303030303030303030303030303030303030303030373730303030303030303030303030303030303030303030303030303030303030303030303030323535343434343435353230303030303030303030300a32636463636463323235356135353532")
    (hex 58624 "323934393934393232336233336233323030303030303030303030303030303030373737303037303030303730303030303030373730303030303030303030303030303030303030303030303030303030303030303030303032353534343434343434353532303030303030303030300a32636364646363323234346134343432323934393934393232336233336233323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303235353434343434343434343535323030303030303030300a3264636363636432323434343434")
    (hex 58880 "3432323934393934393232336233336233323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030323535343434343434343434343435353230303030303030300a30326464646432303234343434343432303239343439323030323362623332303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303032353535353535353535353535353535353532303030303030300a303032323232303030323232")
    (hex 59136 "32323230303032323232303030303232323230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030323235353434343434343434343434343434343535323230303030300a30303030303030303030323232323030303232323232323030303030323030303030303030303030303030303037616161616130303030303030303030303030303030303030303030303737303730303030373730373030303030303030303030303232353535353535353535353535353535353535353535353532323030300a30323232323232303032")
    (hex 59392 "646464643230326665666566653230303232343230303030303030303030303030376161616161616161613030303030303030303030303030303030303030373838373837303037383837383730303030303030303030323535353535353535353535353535353535353535353535353535353230300a32646464646464323032366464646432326666666666663230323362336232303030303030303030303037616161613961616161616130303030303030303030303030373030303037386538383838373738653838383837303030303030303030303232323235323232323232323232323232323232323235323232323030300a3235356135353532")
    (hex 59648 "3236646464646432323333333333333232336233623362323030303030303030303761616161393939616161616161303030303030303030303037363730303037386538383838373738653838383837303030303030303030303030303235323232323232323232323232323232323235323030303030300a32646461646464323264646464646432323333333333333232336233623362323030303030303030303761616161613961613939616161303030303730303030303030373030303037383838383838373738383838383837303030303030303030303030303235323535353535353535353535353535353235323030303030300a326464646464")
    (hex 59904 "64323235646464643532323333333333333232336233623362323030303030303030376161616161616161393939396161613030303030303030303030303030303030373838383837303037383838383730303030303030303030303030303235323539393539393935393939353939353235323030303030300a32646464646464323235353535353532303232323232323030323362336232303030303030303030376161616161616161393939396161613030303030303030303030303030303030303738383730303030373838373030303030303030303030303030303235323539393539393935393939353939353235323030303030300a30323232")
    (hex 60160 "323232303032323232323230303030303030303030303232323230303030303030303030376161396161616161613939616161613030303030303030303030303030303030303037373030303030303737303030303030303030303030303030303235323539393539393935393939353939353235323030303030300a30303030303030303030323232323030303030303030303030323232323232303030303030303030376139393961616161616161616161613030303030303030303030303030303030303030303030303030303030303030303030303030303030303030323235323539393539393935393939353939353235323230303030300a3032")
    (hex 60416 "3232323232303032383838383230303030303030303032666566656665323030303030303030376161396161616161616161616161613030303030303030303030303030303030303030303030303030303030303030303030303030303030303032353535353535353535353535353535353535353535353532303030300a32383838643838323032363864643832303030303030303032666666666666323030303030303030376161616161616161616161616161613030303030303030303030373030303030303037303030303030303030303030303030303730303030303032323232323232323232323232323232323232323232323232303030300a")
    (hex 60672 "32353561353835323236643864646432303030303030303032373737373737323030303030303030303761616161616161616161616161303030303730303030303037313730303030303737373030303030303030303030303030373730303030303030303030303030303030303030303030303030303030303030303030300a32386461646464323264646464386432303030303030303032333333333333323030303030303030303761616161616139396161616161303030303730303030303030373030303030303037303030303030303730303030303030373030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 60928 "300a32646464643864323235646464643532303030303030303032333333333333323030303030303030303037616161616139396161616130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3264646464646432323535353535353230303030303030303032323232323230303030303030303030303037616161616161616161303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 61184 "3030300a30323232323232303032323232323230303030303030303030303030303030303030303030303030303030303037616161616130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a353535353535353535353035303530353535353535353535303737373737373030373737373737303030373737373730303737373737303030373737373737303037373737373730303737373737373030373730303737303037373737373730303030303030306565653030303030303030303061303061613030")
    (hex 61440 "61303030300a35353535353535353530353035303535353035303530353030373737373737303037373737373730303737373737373030373730303737303037373737373730303737373737373030373737373737303037373030373730303737373737373030303030303065656565653030303030303030306161616161616161303030300a35353535353535353535303530353035303530353035303530373730303737303037373030373730303737303030303030373730303737303037373030303030303737303030303030373730303030303037373030373730303030373730303030303030306565656565656530303030306130616161616161")
    (hex 61696 "616161613061300a35353535353535353530353035303535353035303530353030373737373737303037373737373030303737303030303030373730303737303037373737373030303737373737303030373730373737303037373737373730303030373730303030303038386565656565656538383030303061616161616161616161616130300a3535353535353535353530353035303530353035303530353037373030373730303737373737373030373730303030303037373030373730303737303030303030373730303030303037373030303730303737303037373030303037373030303030303838386565656565383838303030306161616139")
    (hex 61952 "3939396161616130300a35353535353535353530353035303535353035303530353030373730303737303037373030373730303737303030303030373730303737303037373030303030303737303030303030373737373737303037373030373730303030373730303030306565383865323232653838656530616161616139393939393961616161610a353535353535353535353035303530353035303530353035303737303037373030373737373737303037373737373730303737303037373030373737373737303037373030303030303737373737373030373730303737303037373737373730306565656565383231323865656565653061616139")
    (hex 62208 "39393939393939616161300a35353535353535353530353035303535353535353535353530373730303737303037373737373730303037373737373030373737373730303037373737373730303737303030303030373737373737303037373030373730303737373737373030656565656532323132326565656565616161613939393939393939616161610a30303130303030303030303030303030303030303030303030373737373737303037373030373730303737303030303030373737373737373037373737373730303737373737373030373737373737303037373737373730303737373737373030656565656532323132326565656565616161")
    (hex 62464 "613939393939393939616161610a31313131313131313030303030303030303030303030303030373737373737303037373030373730303737303030303030373737373737373037373737373730303737373737373030373737373737303037373737373730303737373737373030306565656538323132386565656530306161613939393939393939616161300a3030303030313030303030303030303030303030303030303030303737303030303737373737373030373730303030303037373037303737303737303037373030373730303737303037373030303730303737303037373030373730303737303030306538386532323265383865303061")
    (hex 62720 "6161616139393939393961616161610a31313131313131313030303030313030303030303030303030303037373030303037373737303030303737303030303030373730373037373037373030373730303737303037373030373737373737303037373030373730303737373737373030303038383865656565653838383030303061616161393939396161616130300a303031303030303030303130313030303030313030303030303030373730303030373737373737303037373030303030303737303730373730373730303737303037373030373730303737303030303030373730303737303037373737373030303030383865656565656565383830")
    (hex 62976 "30303061616161616161616161616130300a31313131313131313030313031303130303031303130303030373737373030303037373030373730303737303030303030373730373037373037373030373730303737373737373030373730303030303037373737373730303737303737373030303030303065656565653030303030306130616161616161616161613061300a30303030303130303030303030303030303030303030303030373737373030303037373030373730303737373737373030373730373037373037373030373730303737373737373030373730303030303037373737373037303737303037373030303030303030656565303030")
    (hex 63232 "303030303030306161616161616161303030300a31313131313131313030303030303030303030303030303030373737373030303037373030373730303737373737373030373730303037373037373030373730303737373737373030373730303030303030373737373737303737303037373030303030303030303030303030303030303030306130306161303061303030300a3030303030303030303030303030303030303130303030303037373737373730303737373737373030373730303737303037373030373730303737303030373730373730303737303037373030373730303737373737373030373737373737303030303030303030303030")
    (hex 63488 "3034303030303030303030306330303030303030300a30303030303030303030303030303030313131646431313130373737373737303037373737373730303737303037373030373730303737303037373037303737303737303037373030373730303737303037373737373730303737373737373030303030303030303030303434303030303030303030306330303030303030300a303030303230303030303030323030303030643030643030303737303030303030303037373030303037373030373730303737303037373030373730373037373030373737373030303737303037373030303030303737303037373030373730303030303030303034")
    (hex 63744 "34343934303030303030303030636363303030303030300a30303232373232303030323265323230316435646435643130373737373737303030303737303030303737303037373030373730303737303037373037303737303030373730303030373737373737303030303037373730303737303037373030303030303034343939393934303030303030633030306330303063303030300a30323732363237323032653265326532306464353564643030373737373737303030303737303030303737303037373030373730303737303037373037303737303037373737303030303737373730303030303737373030303737303037373030303030303439")
    (hex 64000 "393939393934303030303030306363306330636330303030300a30323632363236323032363236323632316464646464643130303030303737303030303737303030303737303037373030373730303737303037373037303737303737303037373030303037373030303030373737303030303737303037373030303030343939393939393934303030303030306363636363636330303030300a3031323132313231303132313231323130306464646430303037373737373730303030373730303030373737373737303030373737373030303737303730373730373730303737303030303737303030303737373737373030373737373737303030303034")
    (hex 64256 "3939393939393934303030303063303063306330633030306330300a30303030303030303030303030303030313131313131313130373737373737303030303737303030303737373737373030303037373030303037373737373737303737303037373030303037373030303037373737373730303737373737373030303034393939393439393934303030636363636363636363636363636363630a303030323232303030303032323230303030303030303030303037373730303030373737373737303037373737373730303737303037373030373737373737303037373030303030303737373737373030373737373737303037373737373730303034")
    (hex 64512 "39393939343939393934303030303063303063306330633030306330300a30303236363632303030326536363230303030303030303030373737373030303037373737373730303737373737373030373730303737303037373737373730303737303030303030373737373737303037373737373730303737373737373030303439393939343939393934303030303030306363636363636330303030300a30303236363632303030323636653230303030303030303030373737373030303030303030373730303030303037373030373730303737303037373030303030303737303030303030303030303737303037373030373730303737303037373030")
    (hex 64768 "303439393934393939393430303030303030306363306330636330303030300a30323736373637323032653637366532303030303030303030303037373030303037373737373730303037373737373030373737373737303037373737373730303737373737373030303030303737303037373737373730303737373737373030303439393439393939393430303030303030633030306330303063303030300a3030323636363230303032363665323030303030303030303030303737303030303737373737373030303737373737303037373737373730303737373737373030373737373737303030303030373730303737303037373030373737373737")
    (hex 65024 "3030303439343939393939343030303030303030303030636363303030303030300a30323736373637323032373637656532303030303030303030303037373030303037373030303030303030303037373030303030303737303030303030373730303737303037373030303030303737303037373030373730303030303037373030303034393939393434303030303030303030303030306330303030303030300a303032363636323030303236363632303030303030303030303737373737373030373737373737303037373737373730303030303037373030373737373737303037373737373730303030303037373030373737373737303030303030")
    (hex 65280 "37373030303034343434343030303030303030303030303030306330303030303030300a30313231313132313031323131313231303030303030303030373737373737303037373737373730303737373737373030303030303737303037373737373730303737373737373030303030303737303037373737373730303030303037373030303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333")
    (hex 65536 "333333333330303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a3333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333")
    (hex 65792 "3333333333333330303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333030303333333333333333333333333333333333333333333333333333333333303030333333333333333333333333333333333333333333333333333333333330303033333333333333333333333333333330303030303030303030303030303232323030303030303030303030303030300a333333333333333333333333333035353530333333333333333333333333333333333333333333333333333333303535353033333333333333333333333333333333333333333333333333333330353535303333333333")
    (hex 66048 "33333333333333333330303030303030303030303030323535353230303030303030303030303030300a33333333333333333333333333303535353033333333333333333333333333333333333333333333333333333330353535303333333333333333333333333333333333333333333333333333333035353530333333333333333333333333333330303030303030303030303030323535353230303030303030303030303030300a33333333333333333333333333303535353033333333333333333333333333333333333333333333333333333330353535303333333333333333333333333333333333333333333333333333333035353530333333")
    (hex 66304 "333333333333333333333330303030303030303030303030323535353230303030303030303030303030300a33333333333333333333333333303535353033333333333333333333333333333333333333333333333333333330353535303333333333333333333333333333333333333333333333333333333035353530333333333333333333333333333330303030303030303030303030323535353230303030303030303030303030300a3333333333333333333333333035353435353033333333333333333333333333333333333333333333333333303535343535303333333333333333333333333333333333333333333333333330353534353530")
    (hex 66560 "3333333333333333333333333330303030303030303030303032353534353532303030303030303030303030300a33333333333333333333333035353434343535303333333333333333333333333333333333333333333333303535343434353530333333333333333333333333333333333333333333333330353534343435353033333333333333333333333330303030303030303030303235353434343535323030303030303030303030300a333333333333333333333035353434343434353530333333333333333333333333333333333333333333303535343434343435353033333333333333333333333333333333333333333330353534343434")
    (hex 66816 "34353530333333333333333333333330303030303030303030323535343434343435353230303030303030303030300a33333333333333333330353534343434343434353530333333333333333333333333333333303030303030303030303030303030303030303030333333333333333333333333333333303535343434343434343535303333333333333333333330303030303030303032353534343434343434353532303030303030303030300a33333333333333333035353434343434343434343535303333333333333333333333333330353535353535353535353535353535353535353535303333333333333333333333333330353534343434")
    (hex 67072 "343434343435353033333333333333333330303030303030303235353434343434343434343535323030303030303030300a33333333333333303535343434343434343434343435353033333333333333333333333333303030303030303030303030303030303030303030333333333333333333333333333035353434343434343434343434353530333333333333333330303030303030323535343434343434343434343435353230303030303030300a3333333333333035353535353535353535353535353535353033333333333333333333333333303535353535353535353535353535353535303333333333333333333333333330353535353535")
    (hex 67328 "3535353535353535353535303333333333333330303030303032353535353535353535353535353535353532303030303030300a33333333303035353434343434343434343434343434343535303033333333333333333333303535343434343434343434343434343434353530333333333333333333333330353534343434343434343434343434343435353033333333333330303030323235353434343434343434343434343434343535323230303030300a333330303535353535353535353535353535353535353535353535303033333333333030303030303030303030303030303030303030303030303030303333333333303030303030303030")
    (hex 67584 "30303030303030303030303030303030303033333330303232353535353535353535353535353535353535353535353532323030300a33303535353535353535353535353535353535353535353535353535353033333330353535353535353535353535353535353535353535353535353535303333333035353535353535353535353535353535353535353535353535353530333330323535353535353535353535353535353535353535353535353535353230300a33333030303035303030303030303030303030303030303035303030303333333333303030303530303030303030303030303030303030303530303030333333333330303030353030")
    (hex 67840 "303030303030303030303030303030353030303033333330303232323235323232323232323232323232323232323235323232323030300a33333333333035303030303030303030303030303030303035303333333333333333333333303530303030303030303030303030303030303530333333333333333333333330353030303030303030303030303030303030353033333333333330303030303235323232323232323232323232323232323235323030303030300a3333333333303530353535353535353535353535353535303530333333333333333333333330353035353535353535353535353535353530353033333333333333333333333035")
    (hex 68096 "3035353535353535353535353535353530353033333333333330303030303235323535353535353535353535353535353235323030303030300a33333333333035303539393539393935393939353939353035303333333333333333333333303530353939353939393539393935393935303530333333333333333333333330353035393935393939353939393539393530353033333333333330303030303235323539393539393935393939353939353235323030303030300a333333333330353035393935393939353939393539393530353033333333333333333333333035303539393539393935393939353939353035303333333333333333333333")
    (hex 68352 "30353035393935393939353939393539393530353033333333333330303030303235323539393539393935393939353939353235323030303030300a33333333333035303539393539393935393939353939353035303333333333333333333333303530353939353939393539393935393935303530333333333333333333333330353035393935393939353939393539393530353033333333333330303030303235323539393539393935393939353939353235323030303030300a33333333303035303539393539393935393939353939353035303033333333333333333330303530353939353939393539393935393935303530303333333333333333")
    (hex 68608 "333030353035393935393939353939393539393530353030333333333330303030323235323539393539393935393939353939353235323230303030300a33333330353535353535353535353535353535353535353535353530333333333333333035353535353535353535353535353535353535353535353033333333333333303535353535353535353535353535353535353535353535303333333330303032353535353535353535353535353535353535353535353532303030300a3333333030303030303030303030303030303030303030303030303033333333333333303030303030303030303030303030303030303030303030303333333333")
    (hex 68864 "3333303030303030303030303030303030303030303030303030303333333330303032323232323232323232323232323232323232323232323232303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333")
    (hex 69120 "33333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333")
    (hex 69376 "333333333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333330303030303030303030303030303030303030303030303030303030303030300a5f5f6c6162656c5f5f0a31313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131")
    (hex 69632 "313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 69888 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 70144 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 70400 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3130303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 70656 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a313030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 70912 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 71168 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3130303030303030303030303030303030303030303030303030303030303030303030")
    (hex 71424 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303038383830303030303030303030303030303030303838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a313030303030303030303038383838383030303030303030303030303030303838")
    (hex 71680 "38383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a31303030303030303030383838383838383030303030303030303030303038383838383838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030380a31303030303030303030383838383838383030303030303030303030303038")
    (hex 71936 "383838383838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038380a31303030303030303030383838383838383030303030303030303030303038383838383838303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038380a3130303030303030303030383838383830303030303030303030303030")
    (hex 72192 "3030383838383830303030303030303030303030303030303030303038383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038380a31303030303030303030303038383830303030303030303030303030303030303838383030303030303030303030303030303030303030383838383838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038380a313030303030303030303030303030303030303030303030303030")
    (hex 72448 "30303030303030303030303030303030303030303030303030303030383838383838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038380a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030380a31303030303030303030303030303030303030303030303030")
    (hex 72704 "303030303030303030303030303030303030303030303030303030303038383838383838383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838383830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3130303030303030303030303030303030303030303030")
    (hex 72960 "3030303030303030303030303030303030303030303030303030303030303030383838383838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030383838383838383030303030303030303030303030303030303030383838383838383030303030303030303030303030303030303030303030303030303038383830303030303030303030303030303030303030303030303030303030303030303030310a313030303030303030303030303030303030303030")
    (hex 73216 "30303030383838383838383838383838383030303030303030303030303030303030383838383838383838303030303030303030303030303030303030303030303030303838383838303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303838383838383838383838383838383838303030303030303030303030303838383838383838383838383830303030303030303030303030303030303030303030303838383838303038383838383838383830303030303030303030303030303030303030303030310a31303030303030303030303030303030303030")
    (hex 73472 "303030383838383838383838383838383838383838383030303030303030303038383838383838383838383838383838383030303030303030303030303030303030303030303838383838383838383838383838383838383030303030303030303030303030303030303030310a31303030303030383838383838383030303030303838383838383838383838383838383838383838383838303030303030383838383838383838383838383838383838383838303030303030303030303030303030303030303038383838383838383838383838383838383838303030303030303030303030303030303030310a3130303038383838383838383838383838")
    (hex 73728 "3030383838383838383838383838383838383838383838383838383030303038383838383838383838383838383838383838383838383838303030303838383838383830303030303038383838383838383838383838383838383838383830303030303030303030303030303030300a31303838383838383838383838383838383838383838383838383838383838383838383838383838383838383030303838383838383838383838383838383838383838383838383838383838383838383838383838383038383838383838383838383838383838383838383838383838303030303030303030303030303838380a303838383838383838383838383838")
    (hex 73984 "38383838383838383838383838383838383838383838383838383838383830383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383030303030303030303838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383830303030303038383838383838380a38383838383838383838383838")
    (hex 74240 "383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838")
    (hex 74496 "3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838")
    (hex 74752 "38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838")
    (hex 75008 "383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838")
    (hex 75264 "3838383838383838383838383838383838383838383838383838383838383838373737373737383837373838373738383737373737373838383838383838383837373737373738383737383837373838373737373737383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838373737373737383837373838373738383737373737373838383838383838383837373737373738383737383837373838373737373737383838383838383838383838383838383838383838383838383838383838383838383838380a383838")
    (hex 75520 "38383838383838383838383838383838383838383838383838383838383838383838373738383737383837373838373738383737383837373838383838383838383837373838373738383737383837373838373738383737383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838373737373738383837373838373738383737383837373838383838383838383837373737373838383737383837373838373738383737383838383838383838383838383838383838383838383838383838383838383838383838380a38")
    (hex 75776 "383838383838383838383838383838383838383838383838383838383838383838383838373737373737383837373838373738383737383837373838383838383838383837373737373738383737383837373838373738383737383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383837373838373738383737383837373838373738383737383838383838383838383737383837373838373738383737383837373838373738383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 76032 "0a38383838383838383838383838383838383838383838383838383838383838383838383838373737373737383837373737373738383737383837373838383838383838383837373737373738383737373737373838373738383737383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383737373737373838373737373737383837373838373738383838383838383838373737373737383837373737373738383737383837373838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 76288 "38380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 76544 "383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383861613838383838616161383838383861616138383838386138613838383838616161383838383861616138383838386161613838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838613838383838383861386138383838386161613838383838613861383838383861386138383838386138613838383838386138383838383838383838383838383838383838383838383838383838383838383838")
    (hex 76800 "3838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838386161613838383838616161383838383861386138383838386138613838383838616138383838383861616138383838383861383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383838386138383838386138613838383838613861383838383861386138383838386138613838383838613861383838383838613838383838383838383838383838383838383838383838383838383838383838")
    (hex 77056 "38383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838386161383838383838613861383838383861386138383838383861613838383838613861383838383861386138383838386161613838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 77312 "383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383238323832323838383838383232323832323238383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 77568 "3838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383832383238383238383838383838383238323832383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838323832383832383838383838383232383232323838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 77824 "38383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383832323238383238383838383838383238323832383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838323838323232383832383832323238323832383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 78080 "383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 78336 "3838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 78592 "38383838383838383838383838383838383838380a38383838383838383838323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 78848 "383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 79104 "3838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383232323232323238383838323232323232323832323232323232323238383838323232383838383832323232323232383838383232323238323232323232323232323232383838383232323232323238383838383232323838383838323232323232")
    (hex 79360 "32383838383232323232323232323232323232323232383838380a38383832323737373737323238383832373737323732383237373732373237323838383832373238383838323237373737373232383838323737323232373732373737323737373238383832323737373737323238383838323732383838383232373737373732323838383237373732373732323737373232373732383838380a38383832373732323237373238383832373237323732383237323732373237323838383832373238383838323737373232373732383838323732373237323732373237323737373238383832373732323737373238383838323732383838383237373237")
    (hex 79616 "323737323838383232373232373237323732323237323732383838380a38383832373732373237373238383832373737323732383237373732373737323838383832373238383838323737323232373732383838323732373237323732373732323732373238383832373732323237373238383838323732383838383237373732373737323838383832373232373237323737323237323732383838380a3838383237373232323737323838383237323232373232323732373232323732383838383237323838383832373737323237373238383832373237323732373237323732373237323838383237373232373737323838383832373238383838323737")
    (hex 79872 "3237323737323838383232373232373237323732323237323732383838380a38383832323737373737323238383832373238323737373237323732373737323838383832373238383838323237373737373232383838323732373237373232373237323732373238383832323737373737323238383838323732383838383232373737373732323838383237373732373237323732383237373232383838380a383838383232323232323238383838323232383232323232323232323232323238383838323232383838383832323232323232383838383232323232323232323232323232323232383838383232323232323238383838383232323838383838")
    (hex 80128 "32323232323232383838383232323232323232323232383232323238383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 80384 "383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 80640 "3838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 80896 "38383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 81152 "383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838380a3838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838")
    (hex 81408 "3838383838383838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838303030383838383838383838383838383838383838383838383838383838383838383838383838383838380a383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383030303030383838383838383030")
    (hex 81664 "30303030303030303838383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383830303030303030303030303030303030303030303030303038383838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383030303030303030303030303030")
    (hex 81920 "303030303030303030303030303838383838383838383838383838383838383838383838383838383838383838380a38383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838303030303030303030303030303030303030303030303030303030303030303838383838383838383838383838383838383838383838383838383838380a3038383838383838383838383838383838383838383838383838383838383838383838383838383030383838383838383838383838383838383838383838383838303030303030303030303030303030")
    (hex 82176 "3030303030303030303030303030303030303030303030303030303838383838383838383838383838383838383838380a30303838383838383838383838383838383838383838383838383838383838383838383838303030303038383838383838383838383838383838383838383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838383838383838383838380a313030303838383838383838383838383838383838383838383038383838383838383838303030303030303030383838383838383030303030303030303030303030303030303030303030303030")
    (hex 82432 "30383838383830303030303030303030303030303030303030303030303030303030383838383838383838383838383838380a31303030303030383838383838383030303030303838383838303030303038383838383838303030303030303030303030303030303030303030303030303030303030383838383830303030303038383838383838303030303030303030303030303030303030303030303030303030303038383838383838383838383838380a31303030303030303030303030303030303030303838383838303030303038383838383838303030303030303030303030303030303030303030303030303030303038383838383838303030")
    (hex 82688 "303838383838383838383030303030303030303030303030303838383030303030303030303030303038383838383838303838380a31303030303030303030303030303030303030303038383830303030303038383838383838303030303030303030303030303030303030303030303030303030303838383838383838383030383838383838383838383830303030303030303030303030383838383830303030303030303030303030303838383030303838380a3130303030303030303030303030303030303030303030303030303030303038383838383030303030303030303030303030303030303030303030303030303038383838383838383838")
    (hex 82944 "3830383838383838383838383830303030303030303030303030383838383830303030303030303030303038383838383838383838380a31303030303030303030303030303030303030303030303030303030303030303838383030303030303030303030303030303030303030303030303030303038383838383838383838383838383838383838383838383830303030303030303030303030383838383830303030303030303030303038383838383838383838380a313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030383838383838383838")
    (hex 83200 "38383838383838383838383838383830303030303030303030303030303838383030303030303030303030303838383838383838383838380a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838383838383838383838383838383838383830303030303030303030303030303030303030303030303030303030303838383838383838383838380a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838")
    (hex 83456 "383838383838303838383838383838383030303030303030303030303030303030303030303030303030303030303838383838383838383838380a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838383838383838383838303038383838383838303030303030303838383030303030303030303030303030303030303030303038383838383838303030380a3130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303038383838")
    (hex 83712 "3838383838383830303030383838383830303030303030383838383830303030303030303030303030303030303030303038383838383838303030300a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303838383838383838383030303030303030303030303030303030383838383830303030303030303030303030303030303030303030303838383030303030310a313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 83968 "38383838383838303030303030303030303030303030303030383838383830303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030383838383830303030303030303030303030303030303030303838383030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 84224 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 84480 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 84736 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 84992 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 85248 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 85504 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 85760 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a31303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030310a3131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131")
    (hex 86016 "3131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131313131310a0a5f5f6766665f5f0a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 86272 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030316430313030333830303030303030303030303030303030303030303030666666666666666666663030303030303030303030303030303030303030303066666666666666666666303030303030303030303030303030303030303030306666666666666666666666666666666630303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 86528 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6d61705f5f0a3030303030303030303030303030303030303030303039313030303030303030303030303030303030303030303030303030303030303932303030303030303030303030303030303030303030303030303030303030303030303030303034633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 86784 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30306130303030303030303030303030303030303030303030303030613030303030613030303030303030303030303030303030303030303030303061303030303030303030303030303030303034643465303030303932303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 87040 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303039323030303030303030303030303030303030303030303030303030303030303931303030303030303030303030303030303030303030303030303030303030303030303563356435653566303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 87296 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306130303039323030303036633664366536663030303030303030613030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 87552 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030306130303030303030303030303030613030303932303030303030303030303030303030303030303030303030303030303030393130303030303030303030303030303030376337643765376630303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 87808 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030393230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 88064 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303039313030303030303030303030303030303030303030303030303030303030303932303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 88320 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303039323030303030303030303030303030613030303030303030303030303030303030303030303932303030303030303061303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 88576 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303061303030303030303030303030303030303030303030303030303030303030306130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 88832 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303932303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303039323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 89088 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303039323030303030303030303030303030303030303030303030303030303030303030303030303030303030303932303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 89344 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303061303030303030303030303030306130303030303030303030303030303030303030303030303030303030303030303030303030303030303030393234633464346534663030303030303030346334643465346639313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 89600 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303931303030303030303030303030303030303030303030303030303030303030393130303030303030303030303030303030303030303030303030303030356335643565356630303030303030303563356435653566303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 89856 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303039313030303030303030303030303030303030303030303030303030303030303931303030303030303030303663366436653666303030303030303036633664366536663030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 90112 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303061303030303030303030303061303030303030303030303030306130303030306130303030303030303030306130303030303030303030303030613030303030303037633764376537663030303030303030376337643765376630303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 90368 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303039323030303030303030303030303030303030303030303030303030303030303932303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 90624 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 90880 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a383038303832383238323832383238323832383238323832383238323830383038303830383238323832383238323832383238323832383238323832383038303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 91136 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3830383161303930393039303930393039303930393039303930613038313830383038313930393039303930393039303930393039303930393039303831383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 91392 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303831393039303930393039303930393039303930393039303930383138303830383139303930393039303930393039303930393039303930393038313830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 91648 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a383038313930393039303930393039303930393039303930393039303831383038303831393039303930393039303930393039303930393039303930383138303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 91904 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3830383139303930393061303930393039303930613039303930393038313830383038313930393061303930393039306130393039303930613039303831383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 92160 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303831393039303930393039303930393039303930393039303930383138303830383139303930393039303930393039303930393039303930393038313830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 92416 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a383038313930393039303930393039303930393039303930393039303831383038303831393039303930393039303930393039303930393039303930383138303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 92672 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3830383139303930393039303930393039303930393039303930393038313830383038313930393039303930393039303930393039303930393039303831383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 92928 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303831393039303930393039303930393039303930393039303930383138303830383139303930393039303930393039303930393039303930393038313830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 93184 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a383038313930393039306130393039303930393061303930393039303831383038303831393039306130393039303930613039303930393061303930383138303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 93440 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3830383139303930393039303930393039303930393039303930393038313830383038313930393039303930393039303930393039303930393039303831383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 93696 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303831393039303930393039303930393039303930393039303930383138303830383139303930393039303930393039303930393039303930393038313830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 93952 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a383038316130393039303930393039303930393039303930393061303831383038303831393039303930393039303930393039303930393039303930383138303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 94208 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3830383038323832383238323832383238323832383238323832383238303830383038303832383238323832383238323832383238323832383238323830383030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 94464 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a38303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830383038303830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 94720 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f7366785f5f0a30313031303030303038353530303835353031643535303164353530303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030")
    (hex 94976 "30303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530300a3030303030303030333332353032383135303135323530323031353031613235303161313530313532353031313135303061323530303231353030343235303033313530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303033343235303262313530316631353031343235303235323530313832")
    (hex 95232 "3530313332353031323135303065323530303632353030373135303037323530303932353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303130343030303032373635303237323530313930353032623635303261363530323432353031383035303233363530323034353031353035303164363530316131353031393135303132303530313736353031353635303133313530306330353030663635303065323530306330353030623635303061313530")
    (hex 95488 "3062303530303936353030373235303034303530303231353031333435303039343530303236353030333635300a3030303030303030323236333032343633303237363330326236333033323633303337363330336236333031303133303134313330313831333031643133303231313330323531333032613133303265313330333431303033383130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030323336333032363633303239363330326436333033313633303336363330333836")
    (hex 95744 "333031653133303231313330323531333032373133303261313330333031333033333133303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031303030303030323236333032333633303236363330323936333032643633303332363330333836333031613133303166313330323231333032373133303264313330326631333030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 96000 "303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030316435353032313535303234353530323535353032313535303162353530313635353031323535303064353530303735353030383535303062353530313435353031663535303235353530316235303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530300a30303031303030303364313530333430353031633035303062303530313230353031373035303137303530336637")
    (hex 96256 "30303264313030326230373032633137303333313730333831373033633137303366313730336630373032373730303238373030326137303032623730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730303030373030303037303030303730300a30303031303030303064363530306536353031303635303064313530313336353031353135303137313530316231353031653635303231313530323431353032613635303131363530313136353031303135303131363530316136353031313635303131363530313636353030653135303066313530313136353031613635303131363530")
    (hex 96512 "30663135303135313530303036303030303630303030363030303036303030303630300a3031303230303030326636373032653637303130363730316335373032333535303237353530326235313032653531303331353530333035353032663535303263353530323935353032313535303161353530313835353031613535303232303030323930303032623030303265303030333330303033373030303030303030303230303030323030303032303030303230303030323030303032303030303230303030323030300a336631363030303030663333353132333335313433333531363333353139333335316233333531323333353066333335316533")
    (hex 96768 "3335316233333530663236353030323030306632363530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a336631363030303031623333353139333335313633333531343333353132333335306633333530643333353066333335313233333530663333353066323635303030303530663236353030303035303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 97024 "3030303030303030303030303030303030303030303030303030303030300a3365313630303030316233333531393333353136333335313433333531323333353066333335306433333530663333353136333335306633333530663236353033333035306632363530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3365313630303030306633313530663331353132333135313233313530663331353066333135306433313530643331353066333135306633")
    (hex 97280 "313531323331353132333135313433313531343331353065333135306533313530663331353066333135313233313531323331353066333135306633313530643331353064333135306633313530663331353134333135313433313530643331353064333135303233313530323331350a3365313430303030316632323131663232313166323231316632323132323232313232323231323232323132323232313166323231316632323132323232313232323231316232323131623232313162323231316232323131363232313136323231313632323131363232313162323231316232323131623232313162323231316232323131623232313162323231")
    (hex 97536 "316232323131623232313162323231316232323131623232310a3030303630303030316230353031623035303031303030303130303030313030303032303030303130303030313030303032303030303430303030353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a36383032303030303266363530313830353032663635303231303530323130353031653035303164303530313730353030663035303061303530303830")
    (hex 97792 "35303036303530303630353030333035303032303530303230353030323030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303162313230316331323031663132303230313230323431323032343132303236313230323831323032383132303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030")
    (hex 98048 "30303130303030313030303031303030303130300a3030303030303030313331323031363132303139313230316331323031643132303231313230323231323032353132303237313230303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130303030313030303031303030303130300a303030303030303031333132303135313230313731323031393132303164313230316631323032333132303236313230303030303030303030303030303030303030")
    (hex 98304 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303032633635303262363530323436353032303635303164363530313936353031383635303138363530306633353031303335303132333530313433303031363330303030363030333436303033343630303333363030333336303033323630303332363030333236303030303630303030363030303036303030303630303030363030303036303030303630303030363030")
    (hex 98560 "3030363030303036303030303630300a3030303030303030323936353032343635303231363530316436353031613635303164363530316236353031393635303138363530313736303031363630303134363030313236303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030313035373030643537303063353730306135373030393537303038353730303835373030613537303064353730306635373030303030303030303030303030")
    (hex 98816 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030306430353131313035303137303530316330353031663035303233303530303635303030383530313062353030306535303030653530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030")
    (hex 99072 "303035303030303530300a3030303130303030303730353030373035303039303530306130353030363335303035333530313534353031373435303136373530313637353031393735303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303238363530323636353032333635303166363530316236353031363635303134363530303733353030393335303039333530306333353030643335303030303030303030")
    (hex 99328 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303239363530323636353032333635303164363530316236353031383635303136363530313033353031313335303131333530313533353031373335303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 99584 "30303030300a3030303030303030323736353032343635303231363530316536353031623635303138363530313636353031613335303161333530316233353031643335303166333530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303032373635303234363530323136353031663635303165363530316236353031393635303230333530323033353032323335303234333530323733353030303030303030303030303030")
    (hex 99840 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303032353635303232363530323036353031633635303161363530313936353031383635303233333530323433353032363335303238333530326233353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 100096 "0a3030303030303030323736353032343635303166363530316336353031613635303139363530313736353032613335303263333530326633353033303335303333333530303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030326636353032363635303165363530316236353031373635303135363530316233353030633335303061333530306133353030613335303061333530326433353030393335303039333530303034")
    (hex 100352 "303030313430303031343030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303330303030313636353031393635303037323530323836353032383635303235363530303632353031613635303162363530316136353030373235303162363530316336353030623635303035363530303136353030383630303032363030303136303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630300a30303033")
    (hex 100608 "30303030326436353032643635303037323530313736353031353635303135363530306332353032313635303166363530316636353030373235303232363530316436353031333635303064363530303136353030383630303032363030303136303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630303030363030303036303030303630300a30303032303030303261363530313730353032613635303064363530306436353030663635303131363530313336353031313635303065363530306236353030633635303063363530306436353030653635303066363530306336")
    (hex 100864 "35303062363530306336353030633635303061363530303736353030363635303035363530303436353030333635303032363530303136353030313635303031363530303136353030313635300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030")
    (hex 101120 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 101376 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030")
    (hex 101632 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 101888 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030")
    (hex 102144 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 102400 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030")
    (hex 102656 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 102912 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030")
    (hex 103168 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 103424 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030")
    (hex 103680 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 103936 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 104192 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 104448 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 104704 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 104960 "303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 105216 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 105472 "30303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6d757369635f5f0a30322030653430343034300a30302030653030303030300a30302030303030303030300a3030203030303030")
    (hex 105728 "3030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a")
    (hex 105984 "30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030")
    (hex 106240 "303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a30302030303030303030300a0a")))
