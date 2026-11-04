#lang boba-nes
;; ============================================================================
;; Whole-ROM Decompiled #lang boba-nes Cartridge Module
;; Target     : PICO
;; Game Title : Swordfish (swordfish.p8)
;; Source ROM : assets/roms/pico/swordfish.p8 (87968 bytes, 100% lossless bank-by-bank lift)
;; ============================================================================

(def-whole-rom-cartridge
  (target pico)
  (id "porklike")
  (title "Swordfish (swordfish.p8)")
  (rom-source "pico/swordfish.p8")
  (rom-bytes 87968)
  ;; --- 1. Cartridge Header & Memory Mapper Specification ---
  (header-spec
    (format PICO-8-Cartridge)
    (section-order (header lua gfx label gff map sfx music))
    (lua-line-count 1957)
    (lifted-function-count 102)
    (gfx-row-count 128)
    (map-row-count 32)
    (gff-row-count 2)
    (sfx-row-count 41)
    (music-row-count 17))
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
    (lifted-functions (_draw _init _update abs_box add_shake apply_accel apply_friction arg boldprint bounce bounce_relative cancel_attack change_state check_hazard_colls coll coll_exit coll_ink coll_objs create_bubbles create_clam create_exit create_explosion create_fern create_field create_ink create_mine create_particle create_pearl create_player create_puffer create_school create_shark create_snapper create_spikey create_squid create_trap create_trigger detectwalls dist draw_background draw_boss draw_bubble draw_clam draw_exit draw_explosion draw_fern draw_foreground draw_fx draw_hazards draw_hud draw_ink draw_objects draw_particles draw_pearl draw_player draw_puffer draw_snapper draw_spikey draw_squid draw_titles drawoutline flashobject gettile hurt_player is_offscreen issolid kill_object load_room load_room_data move new_box new_object next_room parse setdirection spawnlist spawntype ternary timer unpack update_boss update_camera update_clam update_exit update_hazards update_ink update_objects update_particles update_pearl update_player update_puffer update_shake update_snapper update_spikey update_squid update_triggers))
    (pico8-api-calls (abs add all btn camera circ circfill cls cos del fget flr map max mget min music pal palt print pset rect rectfill rnd sfx sin spr sqrt))
    (nonblank-sprites-lifted 32)
    (active-map-rows-lifted 32)
    (active-sfx-lifted 32)
    (active-music-lifted 14))
  ;; --- 4. Symbolic MMIO Cross-Reference, Subroutines & Lifted AST ---
  (lifted-lua-functions
    (def-pico-function
      (name load_room_data)
      (params ())
      (line-range (7 27))
      (api-calls (music))
      (called-functions (change_state next_room parse))
      (body-lines
        "function load_room_data()"
        "rooms = {"
        "{"
        "ref=\"-20,-20,\","
        "tiles=\"14,4,-1,\","
        "spawn=\"0,300,150,\","
        "ferns=\"0,104,3,8,8,104,2,9,32,112,2,8,40,112,1,2,49,128,2,8,56,128,3,14,91,128,2,8,104,120,4,2,112,104,4,8,121,104,6,14,128,104,6,8,135,104,5,9,142,104,4,10,149,104,3,15,156,104,2,7,218,104,2,7,225,104,3,15,232,104,4,10,239,104,5,9,246,104,6,8,\","
        "triggers={{"
        "parse\"0,0,0,0,1,\","
        "function()"
        "if titles then"
        "player.off=true"
        "player.dir=2"
        "if t==200 then"
        "titles=false"
        "next_room()"
        "elseif t==80 then music(2)"
        "elseif t>=30 then"
        "change_state(player,\"swim\")"
        "player.vx+=0.3"
        "end"))
    (def-pico-function
      (name _init)
      (params ())
      (line-range (341 376))
      (api-calls ())
      (called-functions (arg load_room load_room_data new_box))
      (body-lines
        "function _init()"
        ""
        "load_room_data()"
        ""
        "room=1"
        "godmode = false"
        ""
        "wtrfrc = 0.94"
        ""
        "gt,gm,deathcounter,freeze,fade=0,0,0,0,0"
        ""
        "camx,camy,shkx,shky = 0,0,0,0"
        ""
        "fades={"
        "0b1111111111111111.1,"
        "0b0111111111011111.1,"
        "0b0101111101011111.1,"
        "0b0101101101011110.1,"
        "0b0101101001011010.1,"
        "0b0001101001001010.1,"
        "0b0000101000001010.1,"
        "0b0000001000001000.1"
        "}"
        ""
        "boss = {"
        "x=52,"
        "y=592,"
        "hp=3,"
        "animt=0,"
        "state=\"dead\","
        "wave=0,"
        "box = new_box(arg\"48,576,80,608,\")"))
    (def-pico-function
      (name _update)
      (params ())
      (line-range (378 384))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function _update()"
        "t+=1"
        "if t>=30000 then t=0 end"
        "if room>1 and room <#rooms then"
        "gt+=1"
        "if gt==1800 then gt=0 gm+=1 end"
        "end"))
    (def-pico-function
      (name _draw)
      (params ())
      (line-range (414 425))
      (api-calls (rectfill))
      (called-functions ())
      (body-lines
        "function _draw()"
        ""
        "if fade>0 then"
        "if fade<=#fades and fadein==false then"
        "fillp(fades[fade])"
        "rectfill(0,0,cmaxx,cmaxy,1)"
        "fade+=1"
        "fillp()"
        "return"
        "else"
        "fadein=true"
        "end"))
    (def-pico-function
      (name update_camera)
      (params ())
      (line-range (466 480))
      (api-calls (max))
      (called-functions ())
      (body-lines
        "function update_camera()"
        "local xoff,yoff,pd = 0,0,player.dir"
        "if pd >= 1 and pd <=3 then xoff = 12 end"
        "if pd >= 5 and pd <=7 then xoff = -12 end"
        "if pd <=1 or pd ==7 then yoff = -12 end"
        "if pd >= 3 and pd <=5 then yoff = 12 end"
        "local xpoint = max(0,player.x-64+(player.vx*14)+xoff)"
        "local ypoint = max(0,player.y-64+(player.vy*14)+yoff)"
        "camx += (xpoint-camx)*0.1"
        "camy += (ypoint-camy)*0.1"
        "if camx>cmaxx-127 then camx=cmaxx-127 end"
        "if camy>cmaxy-127 then camy=cmaxy-127 end"
        "camx +=shkx"
        "camy +=shky"
        "end"))
    (def-pico-function
      (name draw_background)
      (params ())
      (line-range (483 485))
      (api-calls (rectfill))
      (called-functions ())
      (body-lines
        "function draw_background()"
        "rectfill(0,0,cmaxx,cmaxy,1)"
        "end"))
    (def-pico-function
      (name draw_foreground)
      (params ())
      (line-range (488 498))
      (api-calls (all flr map pal))
      (called-functions ())
      (body-lines
        "function draw_foreground()"
        "local mapx,mapy = 0,0"
        "pal(10,0)"
        "for i in all(roomtiles) do"
        "if i == -1 then"
        "mapx=0"
        "mapy+=128"
        "else"
        "map((i%8)*16,flr(i/8)*16,mapx,mapy,16,16,0x1)"
        "mapx+=128"
        "end"))
    (def-pico-function
      (name update_objects)
      (params (objects))
      (line-range (503 506))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function update_objects(objects)"
        "for enemy in all(objects) do"
        "enemy.update(enemy)"
        "end"))
    (def-pico-function
      (name update_hazards)
      (params (hazards))
      (line-range (509 512))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function update_hazards(hazards)"
        "for p in all(hazards) do"
        "p.update(p)"
        "end"))
    (def-pico-function
      (name check_hazard_colls)
      (params (hazards))
      (line-range (515 518))
      (api-calls (all))
      (called-functions (coll))
      (body-lines
        "function check_hazard_colls(hazards)"
        "for p in all(hazards) do"
        "p.coll(p)"
        "end"))
    (def-pico-function
      (name draw_hazards)
      (params (hazards))
      (line-range (521 524))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function draw_hazards(hazards)"
        "for p in all(hazards) do"
        "p.draw(p)"
        "end"))
    (def-pico-function
      (name create_trigger)
      (params (ref exec))
      (line-range (529 539))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function create_trigger(ref,exec)"
        "local t ={"
        "x=ref[1] or 0,"
        "y=ref[2] or 0,"
        "prox=ref[3] or 1,"
        "t=ref[4] or 0,"
        "active=ref[5] or 1,"
        "exec=exec"
        "}"
        "add(triggers,t)"
        "end"))
    (def-pico-function
      (name update_triggers)
      (params (triggers))
      (line-range (541 548))
      (api-calls (all))
      (called-functions (dist))
      (body-lines
        "function update_triggers(triggers)"
        "for trig in all(triggers) do"
        "local kill=false"
        "if trig.prox>0 then"
        "kill=true"
        "if dist(player.x,player.y,trig.x,trig.y)<=trig.prox then"
        "trig.active=1"
        "end"))
    (def-pico-function
      (name update_shake)
      (params ())
      (line-range (563 569))
      (api-calls (abs rnd))
      (called-functions ())
      (body-lines
        "function update_shake()"
        "if abs(shkx)+abs(shky)<0.5 then"
        "shkx,shky=0,0"
        "else"
        "shkx*=-0.5-rnd(0.2)"
        "shky*=-0.5-rnd(0.2)"
        "end"))
    (def-pico-function
      (name draw_objects)
      (params (objects))
      (line-range (572 575))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function draw_objects(objects)"
        "for enemy in all(objects) do"
        "enemy.draw(enemy)"
        "end"))
    (def-pico-function
      (name draw_hud)
      (params ())
      (line-range (578 581))
      (api-calls (circ))
      (called-functions ())
      (body-lines
        "function draw_hud()"
        "for i=106,122,8 do"
        "circ(camx+i-shkx,camy+6-shky,3.5,0)"
        "end"))
    (def-pico-function
      (name draw_titles)
      (params ())
      (line-range (593 597))
      (api-calls ())
      (called-functions (boldprint move))
      (body-lines
        "function draw_titles()"
        "if player.y>=60 and t>=60 and room==1 then"
        "boldprint(\"⬅️➡️⬆️⬇️: move\",32,40)"
        "boldprint(\"❎/🅾️ (hold): attack\",20,50)"
        "end"))
    (def-pico-function
      (name draw_fx)
      (params (fxs))
      (line-range (646 649))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function draw_fx(fxs)"
        "for fx in all(fx) do"
        "fx.draw(fx)"
        "end"))
    (def-pico-function
      (name next_room)
      (params ())
      (line-range (652 655))
      (api-calls ())
      (called-functions (load_room))
      (body-lines
        "function next_room()"
        "room+=1"
        "load_room(room)"
        "end"))
    (def-pico-function
      (name load_room)
      (params (rm))
      (line-range (658 683))
      (api-calls (all max))
      (called-functions (create_player parse))
      (body-lines
        "function load_room(rm)"
        "t=0"
        ""
        "objects={}"
        "fx={}"
        "particles={}"
        "triggers={}"
        "hazards={}"
        ""
        "local r=rooms[rm]"
        ""
        "local roomref={64,64,false}"
        "if r.ref then roomref=parse(r.ref) end"
        ""
        "local px = roomref[1]"
        "local py = roomref[2]"
        "player = create_player(px,py)"
        "camx=max(0,px-54)"
        "camy=max(0,py-64)"
        ""
        "roomtiles=parse(r.tiles)"
        "roomrows = 0"
        "for i in all(roomtiles) do"
        "if i == -1 then"
        "roomrows+=1"
        "end"))
    (def-pico-function
      (name create_player)
      (params (x y))
      (line-range (731 779))
      (api-calls ())
      (called-functions (new_object parse))
      (body-lines
        "function create_player(x,y)"
        "local p=new_object(x,y,\"player\")"
        "p.dir=2"
        "p.hp=3"
        "p.charge=0"
        "p.invinci=0"
        "p.cooldown=0"
        "p.flash=0"
        "p.bigbox=false"
        "p.tpspd = 3"
        ""
        "p.spr_info={"
        "idle = {"
        "up = parse\"7,38,7,39,\","
        "diagu = parse\"32,36,32,34,\","
        "diagd = parse\"40,42,40,44,\","
        "right=parse\"16,18,16,20,\","
        "dt=0.3"
        "},"
        "swim = {"
        "up = parse\"38,39,\","
        "diagu = parse\"36,34,\","
        "diagd = parse\"42,44,\","
        "right=parse\"18,20,\","
        "dt=0.05"
        "},"
        "charge = {"
        "up = {38},"
        "diagu = {32},"
        "diagd = {42},"
        "right={18},"
        "dt=0.2"))
    (def-pico-function
      (name abs_box)
      (params (att))
      (line-range (780 784))
      (api-calls ())
      (called-functions (ternary))
      (body-lines
        "p.abs_box=function(att)"
        "local b,mx,my,pb = 5,0,0,p.bigbox and att"
        "if att and p.state==\"attack\" then"
        "b=ternary(pb,14,8)"
        "end"))
    (def-pico-function
      (name update_player)
      (params (p))
      (line-range (807 823))
      (api-calls (abs))
      (called-functions (apply_friction load_room))
      (body-lines
        "function update_player(p)"
        "p.animt+=0.01"
        ""
        "local state = p.state"
        ""
        "if state==\"dead\" then"
        "p.vy+=0.04"
        "apply_friction(p,wtrfrc)"
        "if abs(p.animt/0.01)%2==0 then p.flash = 0.1 end"
        "if p.animt>=1 then load_room(room) end"
        ""
        "else"
        ""
        "if p.invinci>0 then"
        "p.invinci -= 1"
        "else p.invinci = 0"
        "end"))
    (def-pico-function
      (name draw_player)
      (params (p))
      (line-range (934 949))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function draw_player(p)"
        "local state=p.state"
        "local sinfo=p.spr_info[state]"
        "local flipx,flipy,sprw,sprh,xoff,yoff,sprites = false,false,2,2,-4,-8,{}"
        ""
        "if state==\"hurt\" or state==\"dead\" then"
        "sprites = sinfo.hurt"
        "else"
        "local d = p.dir"
        "if d==0 or d==4 then sprites = sinfo.up sprw=1 end"
        "if d==1 or d==7 then sprites = sinfo.diagu xoff=-8 end"
        "if d==2 or d==6 then sprites = sinfo.right sprh=1 xoff=-8 yoff=-4 end"
        "if d==3 or d==5 then sprites = sinfo.diagd xoff=-8 end"
        "if d==4 or ((d==3 or d==5) and state==\"attack\") then flipy=true end"
        "if d>=5 then flipx=true end"
        "end"))
    (def-pico-function
      (name coll_objs)
      (params ())
      (line-range (964 982))
      (api-calls (all sfx))
      (called-functions (abs_box bounce bounce_relative cancel_attack change_state coll kill_object ternary))
      (body-lines
        "function coll_objs()"
        "for e in all(objects) do"
        ""
        "local att=ternary(player.state==\"attack\" and not e.invinci,true,false)"
        ""
        ""
        "if coll(e.abs_box(),player.abs_box(att)) then"
        "local name = e.name"
        "if name==\"mine\" then change_state(e,\"detonate\") sfx(9)end"
        ""
        "if player.state==\"attack\" then"
        "if e.invinci then"
        "if player.invinci>0 then return end"
        "if name!=\"clam\" then bounce(e,player.vx*0.6,player.vy*0.6) end"
        "cancel_attack()"
        "bounce_relative(player,e,3)"
        "else"
        "kill_object(e)"
        "end"))
    (def-pico-function
      (name hurt_player)
      (params (p))
      (line-range (999 1013))
      (api-calls (rnd sfx))
      (called-functions (add_shake change_state create_bubbles))
      (body-lines
        "function hurt_player(p)"
        "if p.state != \"dead\" then"
        "p.hp-=1"
        "create_bubbles(p.x,p.y,rnd(3)+3,8,2,4)"
        "freeze=3"
        "sfx(6)"
        "add_shake(10)"
        "if p.hp<=0 then"
        "deathcounter+=1"
        "change_state(p,\"dead\")"
        "else"
        "p.charge = 0"
        "p.cooldown = 3"
        "change_state(p,\"hurt\")"
        "end"))
    (def-pico-function
      (name cancel_attack)
      (params ())
      (line-range (1017 1027))
      (api-calls (rnd sfx))
      (called-functions (add_shake change_state create_particle))
      (body-lines
        "function cancel_attack()"
        "change_state(player,\"idle\")"
        "add_shake(3)"
        "sfx(9)"
        "player.charge = 0"
        "player.cooldown = 2"
        "player.flash = 0"
        "player.bigbox=false"
        "for i=1,rnd(4)+3 do"
        "create_particle(player.x,player.y,rnd(3)+-2,rnd(3)+-2,true)"
        "end"))
    (def-pico-function
      (name new_object)
      (params (x y name update draw))
      (line-range (1035 1037))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function new_object(x,y,name,update,draw)"
        "return {x=x,y=y,vx=0,vy=0,animt=0,state=\"idle\",name=name,update=update,draw=draw}"
        "end"))
    (def-pico-function
      (name create_snapper)
      (params (x y))
      (line-range (1039 1051))
      (api-calls ())
      (called-functions (new_object))
      (body-lines
        "function create_snapper(x,y)"
        "local e=new_object(x,y,\"snapper\",update_snapper,draw_snapper)"
        "e.dir=0"
        "e.active=false"
        ""
        "e.spr_info={"
        "idle = {"
        "up = {1,2},"
        "diag = {3,4},"
        "right={5,6},"
        "dt=0.02"
        "}"
        "}"))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1052 1054))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "e.abs_box=function()"
        "return new_box(e.x-3,e.y-3,e.x+3,e.y+3)"
        "end"))
    (def-pico-function
      (name create_school)
      (params (x y))
      (line-range (1059 1066))
      (api-calls (cos rnd sin))
      (called-functions (create_snapper))
      (body-lines
        "function create_school(x,y)"
        "for i=1,6 do"
        "local a=rnd(1)"
        "local d=rnd(20)"
        "local sx=x+d*cos(a)"
        "local sy=y+d*sin(a)"
        "create_snapper(sx,sy)"
        "end"))
    (def-pico-function
      (name update_snapper)
      (params (e))
      (line-range (1070 1087))
      (api-calls ())
      (called-functions (apply_accel dist move setdirection))
      (body-lines
        "function update_snapper(e)"
        "e.animt+=0.01"
        "local d = dist(e.x,e.y,player.x,player.y)"
        "if not e.active then"
        "if d<=120 then e.active=true end"
        "else"
        "local spd,buff=0.1,20"
        "if d<=20 then buff=4 end"
        "local l,r,u,d"
        "if player.x-buff > e.x then e.vx +=spd r=true end"
        "if player.x+buff < e.x then e.vx -=spd l=true end"
        "if player.y-buff > e.y then e.vy +=spd d=true end"
        "if player.y+buff < e.y then e.vy -=spd u=true end"
        "apply_accel(e,1)"
        "setdirection(e,l,r,u,d)"
        ""
        "move(e)"
        "end"))
    (def-pico-function
      (name draw_snapper)
      (params (e))
      (line-range (1090 1101))
      (api-calls (flr))
      (called-functions (drawoutline))
      (body-lines
        "function draw_snapper(e)"
        "local sinfo,flipx,flipy,sprites,d=e.spr_info[e.state],false,false,{},e.dir"
        ""
        "if d==0 or d==4 then sprites = sinfo.up  end"
        "if d==1 or d==3 or d==5 or d==7 then sprites = sinfo.diag end"
        "if d==2 or d==6 then sprites = sinfo.right end"
        "if d>=3 and d<=5 then  flipy=true end"
        "if d>=5 then flipx=true end"
        ""
        "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
        "drawoutline(spri,e.x-4,e.y-4,1,1,flipx,flipy,0,true)"
        "end"))
    (def-pico-function
      (name create_puffer)
      (params (x y))
      (line-range (1103 1116))
      (api-calls ())
      (called-functions (new_object))
      (body-lines
        "function create_puffer(x,y)"
        "local e=new_object(x,y,\"puffer\",update_puffer,draw_puffer)"
        "e.invinci=false"
        ""
        "e.spr_info={"
        "idle = {"
        "sprites = {110,111},"
        "dt=0.02"
        "},"
        "puffed = {"
        "sprites = {78},"
        "dt=0.5"
        "}"
        "}"))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1117 1120))
      (api-calls ())
      (called-functions (new_box ternary))
      (body-lines
        "e.abs_box=function()"
        "local size = ternary(e.state==\"puffed\",7,3)"
        "return new_box(e.x-size,e.y-size,e.x+size,e.y+size)"
        "end"))
    (def-pico-function
      (name update_puffer)
      (params (e))
      (line-range (1126 1137))
      (api-calls (sfx))
      (called-functions (change_state is_offscreen ternary))
      (body-lines
        "function update_puffer(e)"
        "e.animt+=0.01"
        "local os= is_offscreen(e,80)"
        "if os then return end"
        "local state = e.state"
        "local spd = ternary(state==\"puffed\",0.06,0.1)"
        ""
        "if e.animt>1.2 and state==\"idle\" then"
        "change_state(e,\"puffed\")"
        "e.invinci=true"
        "if not os then sfx(23) end"
        "end"))
    (def-pico-function
      (name draw_puffer)
      (params (e))
      (line-range (1153 1161))
      (api-calls (flr))
      (called-functions (drawoutline ternary))
      (body-lines
        "function draw_puffer(e)"
        "local sinfo=e.spr_info[e.state]"
        "local sprites = sinfo.sprites"
        "local flipx,sprw,sprh,xoff,yoff = ternary(player.x>e.x,true,false),1,1,-4,-4"
        ""
        "if e.state==\"puffed\" then xoff,yoff,sprw,sprh,flipx = -8,-8,2,2,not flipx  end"
        "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
        "drawoutline(spri,e.x+xoff,e.y+yoff,sprw,sprh,flipx,false,0,true)"
        "end"))
    (def-pico-function
      (name create_squid)
      (params (x y shark))
      (line-range (1163 1170))
      (api-calls ())
      (called-functions (new_object))
      (body-lines
        "function create_squid(x,y,shark)"
        "local e=new_object(x,y,\"squid\",update_squid,draw_squid)"
        "e.up=false"
        "e.invinci=false"
        "local sa,sb= 76,77"
        "if shark then"
        "e.name,e.up,sa,sb=\"shark\",true,74,90"
        "end"))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1182 1186))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "e.abs_box=function()"
        "local xa,ya=3,7"
        "if e.name==\"shark\" then xa,ya=7,3 end"
        "return new_box(e.x-xa,e.y-ya,e.x+xa,e.y+ya)"
        "end"))
    (def-pico-function
      (name create_shark)
      (params (x y))
      (line-range (1191 1193))
      (api-calls ())
      (called-functions (create_squid))
      (body-lines
        "function create_shark(x,y)"
        "create_squid(x,y,true)"
        "end"))
    (def-pico-function
      (name update_squid)
      (params (e))
      (line-range (1195 1203))
      (api-calls ())
      (called-functions (ternary))
      (body-lines
        "function update_squid(e)"
        "e.animt+=1"
        "if e.name==\"squid\" then"
        "e.up=ternary(e.vy<0,true,false)"
        "e.invinci=ternary(((player.y>e.y-3 and not e.up) or (player.y<e.y+3 and e.up)),true,false)"
        ""
        "else"
        "e.up=ternary(e.vx<=0,true,false)"
        "end"))
    (def-pico-function
      (name draw_squid)
      (params (e))
      (line-range (1220 1230))
      (api-calls (flr))
      (called-functions (ternary))
      (body-lines
        "function draw_squid(e)"
        "local sinfo = e.spr_info[e.state]"
        "local sprites = sinfo.sprites"
        "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
        "local flipy,flipx,xa,ya,sx,sy = false,false,3,7,1,2"
        "if e.name==\"squid\" then"
        "flipy=ternary(e.up,false,true)"
        "else"
        "flipx=ternary(e.up,true,false)"
        "xa,ya,sx,sy=7,3,2,1"
        "end"))
    (def-pico-function
      (name create_spikey)
      (params (x y mine))
      (line-range (1234 1241))
      (api-calls (flr rnd))
      (called-functions (new_object))
      (body-lines
        "function create_spikey(x,y,mine)"
        "local e=new_object(x,y,\"spikey\",update_spikey,draw_spikey)"
        "e.spri=22"
        "e.bob=true"
        "e.flash=0"
        "e.invinci=true"
        ""
        "e.seed = flr(rnd(30))"))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1242 1244))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "e.abs_box=function()"
        "return new_box(e.x-3,e.y-3,e.x+3,e.y+3)"
        "end"))
    (def-pico-function
      (name create_mine)
      (params (x y))
      (line-range (1250 1252))
      (api-calls ())
      (called-functions (create_spikey))
      (body-lines
        "function create_mine(x,y)"
        "return create_spikey(x,y,true)"
        "end"))
    (def-pico-function
      (name create_field)
      (params (x y cols rows xspace yspace mine))
      (line-range (1254 1260))
      (api-calls ())
      (called-functions (create_spikey))
      (body-lines
        "function create_field(x,y,cols,rows,xspace,yspace,mine)"
        "local ypos = y"
        "for i=1,cols do"
        "for i=1,rows do"
        "create_spikey(x,ypos,mine)"
        "ypos+=yspace"
        "end"))
    (def-pico-function
      (name create_trap)
      (params (x y))
      (line-range (1266 1271))
      (api-calls ())
      (called-functions (create_bubbles create_field create_mine))
      (body-lines
        "function create_trap(x,y)"
        "local m = create_mine(x,y)"
        "m.state=\"detonate\""
        "create_field(x-10,y-10,2,2,20,20)"
        "create_bubbles(x,y,14,15,2,4)"
        "end"))
    (def-pico-function
      (name update_spikey)
      (params (e))
      (line-range (1273 1289))
      (api-calls (sfx))
      (called-functions (add_shake bounce_relative create_bubbles create_explosion dist hurt_player ternary))
      (body-lines
        "function update_spikey(e)"
        "e.vy+=ternary(e.bob,0.01,-0.01)"
        ""
        "if (t+e.seed)%30==0 then e.bob = not e.bob end"
        ""
        "if e.state==\"detonate\" then"
        "e.animt+=1"
        "if e.animt>=60 then"
        "create_explosion(e.x,e.y,15)"
        "create_bubbles(e.x,e.y,10,15,2,4)"
        "add_shake(8)"
        "sfx(14)"
        "local pdist = dist(player.x,player.y,e.x,e.y)"
        "if pdist<=30 and player.state != \"hurt\" and player.invinci==0 then"
        "hurt_player(player)"
        "bounce_relative(player,e,9-pdist/4)"
        "end"))
    (def-pico-function
      (name draw_spikey)
      (params (e))
      (line-range (1313 1318))
      (api-calls (pal spr))
      (called-functions (drawoutline flashobject))
      (body-lines
        "function draw_spikey(e)"
        "drawoutline(e.spri,e.x-4,e.y-4,1,1)"
        "flashobject(e,7)"
        "spr(e.spri,e.x-4,e.y-4,1,1)"
        "pal()"
        "end"))
    (def-pico-function
      (name create_clam)
      (params (x y))
      (line-range (1321 1327))
      (api-calls ())
      (called-functions (new_object))
      (body-lines
        "function create_clam(x,y)"
        "local e =new_object(x,y,\"clam\",update_clam,draw_clam)"
        "e.flipx=false"
        "e.wob=true"
        "e.invinci=true"
        "e.shakesound=false"
        ""))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1328 1333))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "e.abs_box=function()"
        ""
        "local box = new_box(e.x-7,e.y-3,e.x+7,e.y+3)"
        "if e.state==\"open\" then box.y1-=4 box.y2+=4 end"
        "return box"
        "end"))
    (def-pico-function
      (name update_clam)
      (params (e))
      (line-range (1338 1350))
      (api-calls (sfx))
      (called-functions (is_offscreen ternary))
      (body-lines
        "function update_clam(e)"
        "e.animt+=1"
        "if is_offscreen(e,60) then return end"
        "if e.state==\"idle\" then"
        "e.flipx=ternary(player.x>e.x,true,false)"
        "if e.animt >=60 then"
        "if not e.shakesound and not is_offscreen(e) then sfx(15) e.shakesound=true end"
        "if t%2==0 then"
        "if e.wob then"
        "e.x+=2"
        "else"
        "e.x-=2"
        "end"))
    (def-pico-function
      (name draw_clam)
      (params (e))
      (line-range (1376 1381))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function draw_clam(e)"
        "local spri,yoff,h=29,-7,1"
        ""
        "if e.state==\"open\" then"
        "spri,yoff,h=8,-15,2"
        "end"))
    (def-pico-function
      (name create_pearl)
      (params (x y vx vy))
      (line-range (1385 1389))
      (api-calls ())
      (called-functions (new_object))
      (body-lines
        "function create_pearl(x,y,vx,vy)"
        "local e=new_object(x,y,\"pearl\",update_pearl,draw_pearl)"
        "e.vx=vx"
        "e.vy=vy"
        ""))
    (def-pico-function
      (name abs_box)
      (params ())
      (line-range (1390 1392))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "e.abs_box=function()"
        "return new_box(e.x-2,e.y-2,e.x+2,e.y+2)"
        "end"))
    (def-pico-function
      (name update_pearl)
      (params (e))
      (line-range (1398 1401))
      (api-calls (del))
      (called-functions ())
      (body-lines
        "function update_pearl(e)"
        "if e.x<-20 or e.x>roomcols*140 or e.y<-20 or e.y>roomrows*140 then"
        "del(objects,e)"
        "end"))
    (def-pico-function
      (name draw_pearl)
      (params (e))
      (line-range (1405 1407))
      (api-calls ())
      (called-functions (drawoutline))
      (body-lines
        "function draw_pearl(e)"
        "drawoutline(26,e.x-2,e.y-2,1,1,false,false,0,true)"
        "end"))
    (def-pico-function
      (name create_exit)
      (params (x y))
      (line-range (1409 1420))
      (api-calls ())
      (called-functions (new_box))
      (body-lines
        "function create_exit(x,y)"
        "local e={"
        "x=x,"
        "y=y,"
        "name='exit',"
        "state='open',"
        "combat=false,"
        "abs_box=new_box(x-4,y-4,x+4,y+4)"
        "}"
        "exit = e"
        "return e"
        "end"))
    (def-pico-function
      (name update_exit)
      (params ())
      (line-range (1422 1428))
      (api-calls (all))
      (called-functions ())
      (body-lines
        "function update_exit()"
        "if exit.combat==true and exit.state==\"closed\" then"
        "local no = 0"
        "for i in all(objects) do"
        "if i.name==\"mine\" or i.name==\"spikey\" or i.name==\"pearl\" then"
        "no+=1"
        "end"))
    (def-pico-function
      (name coll_exit)
      (params ())
      (line-range (1439 1444))
      (api-calls (sfx))
      (called-functions (abs_box coll next_room))
      (body-lines
        "function coll_exit()"
        "if coll(exit.abs_box,player.abs_box()) then"
        "if exit.state==\"open\" and player.state!=\"dead\" then"
        "sfx(29)"
        "next_room()"
        "end"))
    (def-pico-function
      (name draw_exit)
      (params ())
      (line-range (1448 1456))
      (api-calls (pal spr))
      (called-functions ())
      (body-lines
        "function draw_exit()"
        "local ca,cb=0,0"
        "if exit.state==\"closed\" then ca,cb= 13,2 end"
        "pal(8,0)"
        "pal(9,ca)"
        "pal(10,cb)"
        "spr(108,exit.x-8,exit.y-8,2,2)"
        "pal()"
        "end"))
    (def-pico-function
      (name create_ink)
      (params (x1 y1 x2 y2 uprate both))
      (line-range (1458 1471))
      (api-calls (add))
      (called-functions (new_box))
      (body-lines
        "function create_ink(x1,y1,x2,y2,uprate,both)"
        "e = {"
        "box=new_box(x1,y1,x2,y2),"
        "uprate=uprate or 0,"
        "both=both or false,"
        "name=\"ink\","
        "update=update_ink,"
        "coll=coll_ink,"
        "draw=draw_ink"
        "}"
        "e.uprate*=0.1"
        "add(hazards,e)"
        "return e"
        "end"))
    (def-pico-function
      (name update_ink)
      (params (e))
      (line-range (1473 1488))
      (api-calls (del flr rnd))
      (called-functions (coll create_particle new_box))
      (body-lines
        "function update_ink(e)"
        "local box=e.box"
        "box.y1-=e.uprate"
        "if e.both then box.y2-=e.uprate end"
        "if box.y2<0 then del(hazards,e) end"
        ""
        "local cbox =new_box(camx-20,camy-20,camx+148,camy+148)"
        ""
        "if coll(box,cbox) then"
        "if t%3==0 then"
        "local x1,y1,x2,y2=box.x1,box.y1,box.x2,box.y2"
        "local tblen,rllen,off = x2-x1,y2-y1,10"
        "for i=1, flr((tblen+64)/64) do"
        "create_particle(flr(rnd(tblen)+x1),y1+off,0,(rnd(0.2)+0.2+e.uprate)*-1)"
        "create_particle(flr(rnd(tblen)+x1),y2-off,0,rnd(0.2)+0.2-(e.uprate*0.9))"
        "end"))
    (def-pico-function
      (name coll_ink)
      (params (e))
      (line-range (1497 1506))
      (api-calls ())
      (called-functions (abs_box bounce_relative coll hurt_player))
      (body-lines
        "function coll_ink(e)"
        "local box = e.box"
        "local ps = player.state"
        "if coll(box,player.abs_box()) and ps!=\"attack\" and ps!=\"hurt\" and ps!=\"dead\" then"
        "local centre = {}"
        "centre.x = box.x1+box.x2/2"
        "centre.y = box.y1+box.y2/2"
        "hurt_player(player)"
        "bounce_relative(player,centre,2)"
        "end"))
    (def-pico-function
      (name draw_ink)
      (params (e))
      (line-range (1509 1514))
      (api-calls (pal palt rectfill))
      (called-functions ())
      (body-lines
        "function draw_ink(e)"
        "local b = e.box"
        "palt(0,false)"
        "rectfill(b.x1,b.y1,b.x2,b.y2,0)"
        "pal()"
        "end"))
    (def-pico-function
      (name update_boss)
      (params ())
      (line-range (1517 1532))
      (api-calls (all sfx))
      (called-functions (abs_box add_shake cancel_attack change_state coll kill_object))
      (body-lines
        "function update_boss()"
        "boss.animt+=1"
        "if boss.wave>0 then boss.wave-=1 player.vy-=0.4 add_shake(1)end"
        "if boss.state==\"active\" then"
        "if coll(player.abs_box(),boss.box) then"
        "if player.state==\"attack\" then"
        "cancel_attack()"
        "sfx(21)"
        "boss.hp-=1"
        "add_shake(4)"
        "if boss.hp<=0 then"
        "sfx(22)"
        "change_state(boss,\"dying\")"
        "for i in all(objects) do"
        "kill_object(i)"
        "end"))
    (def-pico-function
      (name draw_boss)
      (params ())
      (line-range (1552 1562))
      (api-calls (spr))
      (called-functions (arg drawoutline))
      (body-lines
        "function draw_boss()"
        "drawoutline(arg\"69,48,576,4,4,false,false,0,true,\")"
        "if boss.hp<3 then"
        "spr(arg\"73,69,596,\")"
        "if boss.hp<2 then"
        "spr(arg\"73,52,596,1,1,false,true,\")"
        "spr(arg\"73,66,580,1,1,true,\")"
        "if boss.hp<1 then"
        "spr(arg\"73,56,581,1,1,true,true,\")"
        "spr(arg\"73,62,588,1,1,\")"
        "end"))
    (def-pico-function
      (name spawnlist)
      (params (l))
      (line-range (1570 1575))
      (api-calls ())
      (called-functions (parse spawntype))
      (body-lines
        "function spawnlist(l)"
        "local ol = parse(l)"
        "for i=1,#ol,3 do"
        "local t,x,y=ol[i],ol[i+1],ol[i+2]"
        "spawntype(t,x,y)"
        "end"))
    (def-pico-function
      (name spawntype)
      (params (type x y))
      (line-range (1578 1597))
      (api-calls ())
      (called-functions (create_clam create_exit create_mine create_puffer create_school create_shark create_snapper create_spikey create_squid))
      (body-lines
        "function spawntype(type,x,y)"
        "if type==3 then"
        "create_snapper(x,y)"
        "elseif type==4 then"
        "create_puffer(x,y)"
        "elseif type==5 then"
        "create_squid(x,y)"
        "elseif type==1 then"
        "create_spikey(x,y)"
        "elseif type==2 then"
        "create_mine(x,y)"
        "elseif type==0 then"
        "create_exit(x,y)"
        "elseif type==6 then"
        "create_clam(x,y)"
        "elseif type==7 then"
        "create_school(x,y)"
        "elseif type==8 then"
        "create_shark(x,y)"
        "end"))
    (def-pico-function
      (name coll)
      (params (a b))
      (line-range (1600 1602))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function coll(a,b)"
        "return not (a.x1>b.x2 or a.y1>b.y2 or a.x2<b.x1 or a.y2<b.y1)"
        "end"))
    (def-pico-function
      (name move)
      (params (o))
      (line-range (1604 1607))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function move(o)"
        "o.x+=o.vx"
        "o.y+=o.vy"
        "end"))
    (def-pico-function
      (name kill_object)
      (params (e))
      (line-range (1609 1615))
      (api-calls (flr rnd))
      (called-functions (add_shake create_bubbles create_explosion create_particle))
      (body-lines
        "function kill_object(e)"
        "add_shake(5)"
        "create_explosion(e.x,e.y,5)"
        "create_bubbles(e.x,e.y,rnd(2)+2,4,1,3)"
        "for i=1,flr(rnd(4)+3) do"
        "create_particle(e.x,e.y,rnd(3)+-2,rnd(3)+-2,true)"
        "end"))
    (def-pico-function
      (name apply_friction)
      (params (o fric))
      (line-range (1622 1625))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function apply_friction(o,fric)"
        "o.vx*=fric"
        "o.vy*=fric"
        "end"))
    (def-pico-function
      (name bounce)
      (params (o bx by))
      (line-range (1627 1630))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function bounce(o,bx,by)"
        "if bx then o.vx = bx end"
        "if by then o.vy = by end"
        "end"))
    (def-pico-function
      (name bounce_relative)
      (params (p o str))
      (line-range (1632 1639))
      (api-calls ())
      (called-functions (bounce dist))
      (body-lines
        "function bounce_relative(p,o,str)"
        "local rdist = dist(p.x,p.y,o.x,o.y)"
        "local bouncex = (p.x-o.x)/rdist"
        "local bouncey = (p.y-o.y)/rdist"
        "bouncex*=str"
        "bouncey*=str"
        "bounce(p,bouncex,bouncey)"
        "end"))
    (def-pico-function
      (name change_state)
      (params (o state))
      (line-range (1641 1645))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function change_state(o,state)"
        "if o.state != state then"
        "o.state = state"
        "o.animt = 0"
        "end"))
    (def-pico-function
      (name apply_accel)
      (params (o tpspd))
      (line-range (1648 1653))
      (api-calls (min))
      (called-functions (dist))
      (body-lines
        "function apply_accel(o,tpspd)"
        "local l=dist(o.vx,o.vy)"
        "local rl=min(l,tpspd)"
        "o.vx=o.vx/l*rl"
        "o.vy=o.vy/l*rl"
        "end"))
    (def-pico-function
      (name issolid)
      (params (x y))
      (line-range (1655 1664))
      (api-calls (fget flr mget))
      (called-functions (gettile))
      (body-lines
        "function issolid(x, y)"
        "local tile,col,row = gettile(x,y)"
        "if tile then"
        "ox = (x-(col*128))/8"
        "oy = (y-(row*128))/8"
        "offsetx = (tile%8)*16"
        "offsety = flr(tile/8)*16"
        "val=mget(ox+offsetx, oy+offsety)"
        "return fget(val, 1)"
        "end"))
    (def-pico-function
      (name detectwalls)
      (params (o))
      (line-range (1667 1676))
      (api-calls ())
      (called-functions (abs_box issolid))
      (body-lines
        "function detectwalls(o)"
        "local hb = o.abs_box()"
        "local x1,x2,y1,y2,xc,yc=hb.x1,hb.x2,hb.y1,hb.y2,0,0"
        "local adjust = 0.1"
        ""
        "for i=y1,y2 do"
        "if x1-1<0 or issolid(x1-1,i) then"
        "o.x+=adjust"
        "xc+=1"
        "end"))
    (def-pico-function
      (name setdirection)
      (params (o bl br bu bd))
      (line-range (1705 1714))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function setdirection(o,bl,br,bu,bd)"
        "if bu and not(bl or br or bd) then o.dir = 0 end"
        "if br and not(bu or bl or bd) then o.dir = 2 end"
        "if bd and not(bl or bu or br) then o.dir = 4 end"
        "if bl and not(bd or br or bu) then o.dir = 6 end"
        "if (bu and br) and not(bl or bd) then o.dir = 1 end"
        "if (br and bd) and not(bl or bu) then o.dir = 3 end"
        "if (bd and bl) and not(br or bu) then o.dir = 5 end"
        "if (bl and bu) and not(br or bd) then o.dir = 7 end"
        "end"))
    (def-pico-function
      (name add_shake)
      (params (p))
      (line-range (1716 1720))
      (api-calls (cos rnd sin))
      (called-functions ())
      (body-lines
        "function add_shake(p)"
        "local a=rnd(1)"
        "shkx+=p*cos(a)"
        "shky+=p*sin(a)"
        "end"))
    (def-pico-function
      (name is_offscreen)
      (params (o buffer))
      (line-range (1722 1726))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function is_offscreen(o,buffer)"
        "local buf = buffer or 0"
        ""
        "if o.x<camx-buf or o.x>camx+127+buf or o.y<camy-buf or o.y>camy+127+buf then return true end"
        "end"))
    (def-pico-function
      (name create_explosion)
      (params (x y r))
      (line-range (1732 1741))
      (api-calls (add))
      (called-functions ())
      (body-lines
        "function create_explosion(x,y,r)"
        "local e={"
        "x=x,"
        "y=y,"
        "r=r,"
        "p=0,"
        "draw=draw_explosion,"
        "}"
        "add(fx,e)"
        "end"))
    (def-pico-function
      (name draw_explosion)
      (params (s))
      (line-range (1743 1755))
      (api-calls (circfill rnd))
      (called-functions (create_explosion))
      (body-lines
        "function draw_explosion(s)"
        "if s.p<2 then"
        "circfill(s.x,s.y,s.r,0)"
        "elseif s.p<4 then"
        "circfill(s.x,s.y,s.r,7)"
        ""
        "if s.p<3 and s.r>4 then"
        "for i=0,2 do"
        "local x=s.x+rnd(2.2*s.r)-1.1*s.r"
        "local y=s.y+rnd(2.2*s.r)-1.1*s.r"
        "local r=0.25*s.r+rnd(0.5*s.r)"
        "create_explosion(x,y,r)"
        "end"))
    (def-pico-function
      (name create_bubbles)
      (params (x y num spread minsize maxsize))
      (line-range (1767 1777))
      (api-calls (add cos rnd sin))
      (called-functions ())
      (body-lines
        "function create_bubbles(x,y,num,spread,minsize,maxsize)"
        "for i=1,num do"
        "local a=rnd(1)"
        "local b={"
        "x=x+spread*cos(a),"
        "y=y+spread*sin(a),"
        "r=rnd(maxsize-minsize)+minsize,"
        "draw=draw_bubble"
        "}"
        "add(fx,b)"
        "end"))
    (def-pico-function
      (name draw_bubble)
      (params (b))
      (line-range (1780 1785))
      (api-calls (circ circfill del))
      (called-functions ())
      (body-lines
        "function draw_bubble(b)"
        "circ(b.x+0.5,b.y+0.5,b.r,13)"
        "circfill(b.x+0.5-b.r*0.4,b.y+0.5-b.r*0.4,b.r*0.2,6)"
        "b.y-=b.r*0.6"
        "if(b.y<0)then del(fx,b) end"
        "end"))
    (def-pico-function
      (name create_fern)
      (params (x y len col))
      (line-range (1787 1791))
      (api-calls (add flr rnd))
      (called-functions ())
      (body-lines
        "function create_fern(x,y,len,col)"
        "f={x=x,y=y,len=len,col=col,flipx=false,draw=draw_fern}"
        "f.bub=flr(rnd(1080)+720)"
        "add(fx,f)"
        "end"))
    (def-pico-function
      (name draw_fern)
      (params (f))
      (line-range (1793 1802))
      (api-calls (flr pal spr))
      (called-functions (create_bubbles))
      (body-lines
        "function draw_fern(f)"
        "if t%50==0 then f.flipx=not f.flipx end"
        "if flr(t+1080)%f.bub==0 then create_bubbles(f.x+3,f.y,1,1,1,2) end"
        "pal(8,f.col)"
        "for i=1,f.len do"
        "if i==f.len then"
        "spr(105,f.x,f.y-i*8,1,1,f.flipx)"
        "else"
        "spr(121,f.x,f.y-i*8,1,1,f.flipx)"
        "end"))
    (def-pico-function
      (name flashobject)
      (params (o c))
      (line-range (1808 1813))
      (api-calls (pal))
      (called-functions ())
      (body-lines
        "function flashobject(o,c)"
        "if o.flash > 0 then"
        "o.flash-=0.1"
        "for i=0,15 do"
        "pal(i,c)"
        "end"))
    (def-pico-function
      (name drawoutline)
      (params (n x y w h flip_x flip_y c main))
      (line-range (1819 1822))
      (api-calls (pal))
      (called-functions ())
      (body-lines
        "function drawoutline(n,x,y,w,h,flip_x,flip_y,c,main)"
        "for i=1,15 do"
        "pal(i,c)"
        "end"))
    (def-pico-function
      (name boldprint)
      (params (str x y col))
      (line-range (1833 1838))
      (api-calls (print))
      (called-functions ())
      (body-lines
        "function boldprint(str,x,y,col)"
        "c=col or 7"
        "for xx=-1,1 do"
        "for yy=-1,1 do"
        "print(str,x+xx,y+yy,0)"
        "end"))
    (def-pico-function
      (name create_particle)
      (params (x y vx vy pp))
      (line-range (1843 1859))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function create_particle(x,y,vx,vy,pp)"
        "p = {"
        "x=x,"
        "y=y,"
        "vx=vx,"
        "vy=vy,"
        "cols={0,0,2},"
        "size=10,"
        "age=0,"
        "maxage=30"
        "}"
        "if pp then"
        "p.size=1"
        "p.maxage=15"
        "p.cols={7,7,7,6,6,12}"
        "p.pp=true"
        "end"))
    (def-pico-function
      (name update_particles)
      (params ())
      (line-range (1863 1874))
      (api-calls (all del flr))
      (called-functions (is_offscreen))
      (body-lines
        "function update_particles()"
        "for p in all(particles) do"
        "p.age+=1"
        "if p.age==p.maxage or is_offscreen(p,30) then del(particles,p) end"
        "local ci = 1+flr((p.age/p.maxage)*#p.cols)"
        "p.col = p.cols[ci]"
        "if p.age/p.maxage > 0.6 then p.fill = fades[4] end"
        "if p.age/p.maxage > 0.8 then"
        "p.fill = fades[2]"
        "if not p.pp then"
        "p.size=14"
        "end"))
    (def-pico-function
      (name draw_particles)
      (params ())
      (line-range (1881 1886))
      (api-calls (all circfill))
      (called-functions ())
      (body-lines
        "function draw_particles()"
        "for p in all(particles) do"
        "if p.fill then fillp(p.fill) end"
        "circfill(p.x,p.y,p.size,p.col)"
        "fillp()"
        "end"))
    (def-pico-function
      (name parse)
      (params (string))
      (line-range (1892 1906))
      (api-calls (flr))
      (called-functions ())
      (body-lines
        "function parse(string)"
        "local data = {}"
        "local d = \"\""
        "for i=1,#string do"
        "local s = sub(string,i,i)"
        "if s != \",\" then"
        "d=d..s"
        "else"
        "if d==\"true\" then"
        "d=true"
        "elseif d==\"false\" then"
        "d=false"
        "else"
        "d=flr(d)"
        "end"))
    (def-pico-function
      (name arg)
      (params (str))
      (line-range (1914 1916))
      (api-calls ())
      (called-functions (parse unpack))
      (body-lines
        "function arg(str)"
        "return unpack(parse(str))"
        "end"))
    (def-pico-function
      (name unpack)
      (params (t i))
      (line-range (1918 1922))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function unpack(t,i)"
        "i=i or 1"
        "if t[i]!=nil then"
        "return t[i],unpack(t,i+1)"
        "end"))
    (def-pico-function
      (name ternary)
      (params (c a b))
      (line-range (1925 1927))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function ternary(c,a,b)"
        "if c then return a else return b end"
        "end"))
    (def-pico-function
      (name gettile)
      (params (x y))
      (line-range (1929 1934))
      (api-calls (flr))
      (called-functions ())
      (body-lines
        "function gettile(x,y)"
        "local col = flr(x/128)"
        "local row = flr(y/128)"
        "local tile = roomtiles[(roomcols*row)+row+col+1]"
        "return tile,col, row"
        "end"))
    (def-pico-function
      (name dist)
      (params (xa ya xb yb))
      (line-range (1936 1941))
      (api-calls (abs max min sqrt))
      (called-functions ())
      (body-lines
        "function dist(xa,ya,xb,yb)"
        "if xb then xa=xb-xa ya=yb-ya end"
        "local d = max(abs(xa),abs(ya))"
        "local n = min(abs(xa),abs(ya)) / d"
        "return sqrt(n*n +1)*d"
        "end"))
    (def-pico-function
      (name new_box)
      (params (x1 y1 x2 y2))
      (line-range (1943 1945))
      (api-calls ())
      (called-functions ())
      (body-lines
        "function new_box(x1,y1,x2,y2)"
        "return {x1=x1,y1=y1,x2=x2,y2=y2}"
        "end"))
    (def-pico-function
      (name timer)
      (params ())
      (line-range (1947 1951))
      (api-calls (flr))
      (called-functions ())
      (body-lines
        "function timer()"
        "local min,sec=gm,flr(gt/30)"
        "if min<10 then"
        "min=\"0\"..min"
        "end")))
  (lifted-pico8-assets
    (gfx-sprites
      (def-pico-sprite #:id 0 #:grid (0 0) #:nonzero-pixels 8 #:rows ("00000000" "00000000" "00700700" "00077000" "00077000" "00700700" "00000000" "00000000"))
      (def-pico-sprite #:id 1 #:grid (1 0) #:nonzero-pixels 36 #:rows ("0088e000" "00178e00" "007788e0" "02888880" "28888220" "00882200" "00888000" "08828000"))
      (def-pico-sprite #:id 2 #:grid (2 0) #:nonzero-pixels 36 #:rows ("0088e000" "00178e00" "007788e0" "02888880" "28282820" "00882200" "00888000" "00882800"))
      (def-pico-sprite #:id 3 #:grid (3 0) #:nonzero-pixels 39 #:rows ("000008e8" "00087188" "0e887782" "00828882" "ee888820" "88288200" "08282000" "00800000"))
      (def-pico-sprite #:id 4 #:grid (4 0) #:nonzero-pixels 38 #:rows ("000008e8" "00087188" "0e887782" "00888882" "00882820" "08888220" "02882000" "00280000"))
      (def-pico-sprite #:id 5 #:grid (5 0) #:nonzero-pixels 36 #:rows ("000e0000" "e008e000" "8882871e" "28888778" "88888882" "00228820" "00022200" "00000000"))
      (def-pico-sprite #:id 6 #:grid (6 0) #:nonzero-pixels 36 #:rows ("000e0000" "0008e000" "e882871e" "88888778" "28888882" "80288220" "00022200" "00000000"))
      (def-pico-sprite #:id 7 #:grid (7 0) #:nonzero-pixels 27 #:rows ("000c0000" "000c0000" "000c0000" "00cc6000" "0c716000" "0c77c600" "0cccc600" "dccccc60"))
      (def-pico-sprite #:id 9 #:grid (9 0) #:nonzero-pixels 36 #:rows ("0001d000" "001dd500" "001dd500" "001d5dd0" "001dd5d0" "001ddddd" "0001dd5d" "0001ddd5"))
      (def-pico-sprite #:id 10 #:grid (10 0) #:nonzero-pixels 52 #:rows ("00222200" "02e22220" "2e26d222" "226e8d22" "22d88521" "222d5211" "02222110" "00111100"))
      (def-pico-sprite #:id 11 #:grid (11 0) #:nonzero-pixels 12 #:rows ("00000000" "00000000" "00000000" "00000000" "00000077" "00000766" "00000666" "0000666d"))
      (def-pico-sprite #:id 12 #:grid (12 0) #:nonzero-pixels 36 #:rows ("00000000" "00007670" "07777760" "76667770" "66666700" "6d066700" "d0d66700" "0d667000"))
      (def-pico-sprite #:id 13 #:grid (13 0) #:nonzero-pixels 30 #:rows ("00000067" "0d666666" "00dddddd" "00000000" "00dddddd" "0d666666" "00000067" "00000000"))
      (def-pico-sprite #:id 14 #:grid (14 0) #:nonzero-pixels 39 #:rows ("77770000" "66667700" "66666760" "00067776" "66666760" "66667700" "77770000" "00000000"))
      (def-pico-sprite #:id 15 #:grid (15 0) #:nonzero-pixels 39 #:rows ("00060000" "00676000" "07777700" "07676700" "76666670" "76606670" "76606670" "76606670"))
      (def-pico-sprite #:id 16 #:grid (0 1) #:nonzero-pixels 25 #:rows ("00000006" "66000000" "0c6066cc" "0ccccccc" "0cc0dddc" "dd00000d" "00000000" "00000000"))
      (def-pico-sprite #:id 17 #:grid (1 1) #:nonzero-pixels 27 #:rows ("60000000" "cc660000" "c77cc000" "c71ccccc" "ccccc000" "dcc00000" "d0000000" "00000000"))
      (def-pico-sprite #:id 18 #:grid (2 1) #:nonzero-pixels 24 #:rows ("00600006" "00c60000" "0c6c666c" "cccccccc" "0000dddc" "0000000d" "00000000" "00000000"))
      (def-pico-sprite #:id 19 #:grid (3 1) #:nonzero-pixels 27 #:rows ("60000000" "cc660000" "c77cc000" "c71ccccc" "ccccc000" "dcc00000" "d0000000" "00000000"))
      (def-pico-sprite #:id 20 #:grid (4 1) #:nonzero-pixels 24 #:rows ("00000006" "00000000" "000066cc" "666ccccc" "0cc0dddc" "ddd0000d" "0d000000" "00000000"))
      (def-pico-sprite #:id 21 #:grid (5 1) #:nonzero-pixels 27 #:rows ("60000000" "cc660000" "c77cc000" "c71ccccc" "ccccc000" "dcc00000" "d0000000" "00000000"))
      (def-pico-sprite #:id 22 #:grid (6 1) #:nonzero-pixels 32 #:rows ("60000006" "060e2060" "00622600" "0e222220" "02222110" "00d21d00" "0d0110d0" "d000000d"))
      (def-pico-sprite #:id 23 #:grid (7 1) #:nonzero-pixels 25 #:rows ("d0cccc00" "00ccc000" "00dcc000" "00ddc000" "000c0000" "00cc6000" "0cddd600" "0d000c00"))
      (def-pico-sprite #:id 24 #:grid (8 1) #:nonzero-pixels 32 #:rows ("00000000" "000000ff" "0002efee" "d12222ee" "ddd11111" "00dddddd" "00000d5d" "00000000"))
      (def-pico-sprite #:id 25 #:grid (9 1) #:nonzero-pixels 44 #:rows ("0001dd5d" "ee001ddd" "eee211d5" "ee2221d0" "111111d0" "dddddd00" "5d5d5000" "00000000"))
      (def-pico-sprite #:id 26 #:grid (10 1) #:nonzero-pixels 21 #:rows ("0f770000" "f7776000" "77776000" "7776d000" "066d0000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 27 #:grid (11 1) #:nonzero-pixels 18 #:rows ("00066dd0" "0006d00d" "00dd000d" "00d000d6" "00000d66" "0000dd00" "00000000" "00000000"))
      (def-pico-sprite #:id 28 #:grid (12 1) #:nonzero-pixels 12 #:rows ("d6670000" "66670000" "66700000" "60000000" "00000000" "00000000" "00000000" "00000000"))
      (def-pico-sprite #:id 29 #:grid (13 1) #:nonzero-pixels 32 #:rows ("00000000" "0000000d" "00d5dd55" "d11d5ddd" "ddd11111" "00dddddd" "00000d5d" "00000000"))
      (def-pico-sprite #:id 30 #:grid (14 1) #:nonzero-pixels 35 #:rows ("00000000" "d5550000" "5ddd5d00" "ddddd1d0" "11111dd0" "dddddd00" "5d5d5000" "00000000"))
      (def-pico-sprite #:id 31 #:grid (15 1) #:nonzero-pixels 30 #:rows ("76d0d670" "66d0d660" "06d0d600" "06d0d600" "06d0d600" "06d0d600" "0d000d00" "00000000"))
      (def-pico-sprite #:id 32 #:grid (0 2) #:nonzero-pixels 11 #:rows ("00000000" "00000000" "00000000" "00000000" "00000006" "0000006c" "00006ccc" "00060ccc")))
    (gff-flags
      (def-pico-sprite-flag #:id 64 #:flags 3)
      (def-pico-sprite-flag #:id 65 #:flags 3)
      (def-pico-sprite-flag #:id 66 #:flags 3)
      (def-pico-sprite-flag #:id 67 #:flags 3)
      (def-pico-sprite-flag #:id 68 #:flags 3)
      (def-pico-sprite-flag #:id 80 #:flags 3)
      (def-pico-sprite-flag #:id 81 #:flags 3)
      (def-pico-sprite-flag #:id 82 #:flags 3)
      (def-pico-sprite-flag #:id 83 #:flags 3)
      (def-pico-sprite-flag #:id 84 #:flags 3)
      (def-pico-sprite-flag #:id 89 #:flags 1)
      (def-pico-sprite-flag #:id 96 #:flags 3)
      (def-pico-sprite-flag #:id 97 #:flags 3)
      (def-pico-sprite-flag #:id 98 #:flags 3)
      (def-pico-sprite-flag #:id 99 #:flags 3)
      (def-pico-sprite-flag #:id 100 #:flags 3)
      (def-pico-sprite-flag #:id 106 #:flags 1)
      (def-pico-sprite-flag #:id 107 #:flags 1)
      (def-pico-sprite-flag #:id 112 #:flags 3)
      (def-pico-sprite-flag #:id 113 #:flags 3)
      (def-pico-sprite-flag #:id 114 #:flags 3)
      (def-pico-sprite-flag #:id 115 #:flags 3)
      (def-pico-sprite-flag #:id 116 #:flags 3)
      (def-pico-sprite-flag #:id 122 #:flags 1)
      (def-pico-sprite-flag #:id 123 #:flags 1)
      (def-pico-sprite-flag #:id 126 #:flags 3)
      (def-pico-sprite-flag #:id 127 #:flags 3))
    (map-rows
      (def-pico-map-row #:y 0 #:nonzero-tiles 96 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 1 #:nonzero-tiles 92 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 2 #:nonzero-tiles 88 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 3 #:nonzero-tiles 88 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 4 #:nonzero-tiles 89 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 5 #:nonzero-tiles 86 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 6 #:nonzero-tiles 83 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 7 #:nonzero-tiles 89 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 8 #:nonzero-tiles 92 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 9 #:nonzero-tiles 91 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 10 #:nonzero-tiles 80 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 11 #:nonzero-tiles 83 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 12 #:nonzero-tiles 86 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 13 #:nonzero-tiles 92 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 14 #:nonzero-tiles 94 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 15 #:nonzero-tiles 96 #:sample-hex "00000000000000000000000000000000")
      (def-pico-map-row #:y 16 #:nonzero-tiles 94 #:sample-hex "00000000000041444242444242444244")
      (def-pico-map-row #:y 17 #:nonzero-tiles 107 #:sample-hex "00000000414442737364737360736060")
      (def-pico-map-row #:y 18 #:nonzero-tiles 103 #:sample-hex "00000041424273737373736454607373")
      (def-pico-map-row #:y 19 #:nonzero-tiles 109 #:sample-hex "00414264737373737373736064737373")
      (def-pico-map-row #:y 20 #:nonzero-tiles 111 #:sample-hex "00717171717171717171717171717171")
      (def-pico-map-row #:y 21 #:nonzero-tiles 114 #:sample-hex "00515151515151515151515151515151")
      (def-pico-map-row #:y 22 #:nonzero-tiles 111 #:sample-hex "00717171717171717171717171717171")
      (def-pico-map-row #:y 23 #:nonzero-tiles 110 #:sample-hex "00616262626262626273737360607373")
      (def-pico-map-row #:y 24 #:nonzero-tiles 106 #:sample-hex "007a5151515151515151515151515151")
      (def-pico-map-row #:y 25 #:nonzero-tiles 108 #:sample-hex "00007373737373737373737373736073")
      (def-pico-map-row #:y 26 #:nonzero-tiles 110 #:sample-hex "00007373737364737373737373737373")
      (def-pico-map-row #:y 27 #:nonzero-tiles 104 #:sample-hex "006a7171717171717171717171717171")
      (def-pico-map-row #:y 28 #:nonzero-tiles 105 #:sample-hex "00417373737373737373647373737373")
      (def-pico-map-row #:y 29 #:nonzero-tiles 112 #:sample-hex "41424242424242737373737373407373")
      (def-pico-map-row #:y 30 #:nonzero-tiles 122 #:sample-hex "73607373647373647373737373737373")
      (def-pico-map-row #:y 31 #:nonzero-tiles 119 #:sample-hex "73737373607373737373737373737373"))
    (sfx-tracks
      (def-pico-sfx #:id 0 #:editor-mode 1 #:speed 20 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 1 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 4)
      (def-pico-sfx #:id 2 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 4)
      (def-pico-sfx #:id 3 #:editor-mode 0 #:speed 4 #:loop (0 0) #:active-notes 5)
      (def-pico-sfx #:id 4 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 5 #:editor-mode 1 #:speed 6 #:loop (0 0) #:active-notes 4)
      (def-pico-sfx #:id 6 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 6)
      (def-pico-sfx #:id 7 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 7)
      (def-pico-sfx #:id 8 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 9 #:editor-mode 1 #:speed 1 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 10 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 11 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 30)
      (def-pico-sfx #:id 12 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 13 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 14 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 8)
      (def-pico-sfx #:id 15 #:editor-mode 1 #:speed 8 #:loop (0 0) #:active-notes 12)
      (def-pico-sfx #:id 16 #:editor-mode 1 #:speed 4 #:loop (0 0) #:active-notes 6)
      (def-pico-sfx #:id 17 #:editor-mode 1 #:speed 16 #:loop (0 0) #:active-notes 0)
      (def-pico-sfx #:id 18 #:editor-mode 1 #:speed 3 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 19 #:editor-mode 0 #:speed 3 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 20 #:editor-mode 1 #:speed 3 #:loop (0 0) #:active-notes 31)
      (def-pico-sfx #:id 21 #:editor-mode 1 #:speed 5 #:loop (0 0) #:active-notes 11)
      (def-pico-sfx #:id 22 #:editor-mode 1 #:speed 5 #:loop (0 0) #:active-notes 32)
      (def-pico-sfx #:id 23 #:editor-mode 1 #:speed 5 #:loop (0 0) #:active-notes 5)
      (def-pico-sfx #:id 24 #:editor-mode 1 #:speed 5 #:loop (0 0) #:active-notes 5)
      (def-pico-sfx #:id 25 #:editor-mode 1 #:speed 10 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 26 #:editor-mode 1 #:speed 10 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 27 #:editor-mode 1 #:speed 10 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 28 #:editor-mode 1 #:speed 10 #:loop (0 0) #:active-notes 16)
      (def-pico-sfx #:id 29 #:editor-mode 1 #:speed 6 #:loop (0 0) #:active-notes 8)
      (def-pico-sfx #:id 30 #:editor-mode 0 #:speed 16 #:loop (0 0) #:active-notes 0)
      (def-pico-sfx #:id 31 #:editor-mode 0 #:speed 16 #:loop (0 0) #:active-notes 0))
    (music-patterns
      (def-pico-music #:pattern 0 #:flags 0 #:channels (0 66 67 68))
      (def-pico-music #:pattern 1 #:flags 2 #:channels (8 66 67 68))
      (def-pico-music #:pattern 2 #:flags 4 #:channels (10 11 12 13))
      (def-pico-music #:pattern 3 #:flags 0 #:channels (18 19 67 68))
      (def-pico-music #:pattern 4 #:flags 4 #:channels (19 20 67 68))
      (def-pico-music #:pattern 5 #:flags 4 #:channels (25 26 27 28))
      (def-pico-music #:pattern 8 #:flags 1 #:channels (34 35 67 68))
      (def-pico-music #:pattern 9 #:flags 0 #:channels (34 36 67 68))
      (def-pico-music #:pattern 10 #:flags 0 #:channels (34 37 67 68))
      (def-pico-music #:pattern 11 #:flags 0 #:channels (34 37 67 68))
      (def-pico-music #:pattern 12 #:flags 0 #:channels (34 38 67 68))
      (def-pico-music #:pattern 13 #:flags 0 #:channels (34 39 67 68))
      (def-pico-music #:pattern 14 #:flags 0 #:channels (34 37 67 68))
      (def-pico-music #:pattern 15 #:flags 2 #:channels (34 40 67 68))))
  ;; --- 5. Full Bank-by-Bank Code, Subroutines, Data & Assets ---
  (p8-sections
    (p8-section header
      "pico-8 cartridge // http://www.pico-8.com"
      "version 42")
    (p8-section lua
      "--swordfish v1.0"
      "--by dan lambton-howard"
      "-- 2018"
      ""
      "--room data"
      ""
      "function load_room_data()"
      "rooms = {"
      "{"
      "ref=\"-20,-20,\","
      "tiles=\"14,4,-1,\","
      "spawn=\"0,300,150,\","
      "ferns=\"0,104,3,8,8,104,2,9,32,112,2,8,40,112,1,2,49,128,2,8,56,128,3,14,91,128,2,8,104,120,4,2,112,104,4,8,121,104,6,14,128,104,6,8,135,104,5,9,142,104,4,10,149,104,3,15,156,104,2,7,218,104,2,7,225,104,3,15,232,104,4,10,239,104,5,9,246,104,6,8,\","
      "triggers={{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "if titles then"
      "player.off=true"
      "player.dir=2"
      "if t==200 then"
      "titles=false"
      "next_room()"
      "elseif t==80 then music(2)"
      "elseif t>=30 then"
      "change_state(player,\"swim\")"
      "player.vx+=0.3"
      "end"
      "else"
      "if t==10 then"
      "music(0)"
      "player.off=true"
      "player.dir=3"
      "player.vx=4"
      "player.vy=5"
      "end"
      "if t==40 then player.dir=2 player.vx=1 end"
      "if t==60 then player.off=false end"
      "end"
      "end"
      "},{"
      "parse\"200,64,30,0,0,\","
      "function()"
      "titles=true"
      "t=0"
      "end"
      "}}"
      "},"
      ""
      "{"
      "ref=\"32,192,\","
      "tiles=\"18,2,29,16,17,19,20,-1,7,0,2,3,4,28,12,-1,18,29,8,17,17,17,11,-1,\","
      "ferns=\"32,224,2,9,40,224,3,9,182,312,5,9,190,312,5,8,202,312,4,9,220,312,3,9,155,384,7,9,160,384,8,8,190,384,5,9,240,384,8,9,312,56,2,8,324,56,3,9,336,56,4,8,346,56,2,8,470,224,8,8,480,224,8,9,501,232,9,8,517,232,10,9,531,232,6,9,544,232,8,10,558,224,8,9,575,224,8,10,593,232,9,7,605,232,5,10,620,232,7,7,638,232,6,7,\","
      "spawn=\"0,842,342,8,172,70,8,216,232,8,396,68,\""
      "},"
      ""
      "{"
      "ref=\"64,32,\","
      "tiles=\"15,17,-1,12,17,-1,12,17,-1,27,20,-1,17,11,-1,17,15,-1,17,11,-1,\","
      "ferns=\"24,272,3,7,32,280,3,11,40,456,2,7,80,464,4,7,96,480,4,7,108,480,2,11,120,488,5,7,127,488,3,3,134,488,4,11,144,496,4,3,152,520,6,11,\"..\"144,656,3,3,152,664,3,3,160,696,5,3,224,696,6,3,232,664,4,11,240,656,5,3,\","
      "spawn=\"0,192,832,8,72,172,8,82,300,8,64,378,8,148,632,8,234,646,\""
      "},"
      ""
      "{"
      "tiles=\"3,4,5,21,-1,\","
      "ferns=\"110,104,2,3,134,104,2,3,149,104,4,3,230,104,3,3,237,104,3,3,269,104,2,3,374,104,2,3,398,104,2,3,413,112,5,3,422,112,4,3,446,104,2,3,461,104,4,3,\","
      "spawn=\"0,448,64,1,140,40,1,220,65,1,220,80,1,220,95,1,344,60,1,310,95,\""
      "},"
      ""
      "{"
      "tiles=\"4,7,0,0,3,-1,\","
      "ferns=\"100,104,2,3,134,96,2,3,149,96,3,3,230,96,2,3,239,104,3,3,516,112,2,3,534,112,3,3,549,112,6,3,622,104,4,3,\","
      "spawn=\"0,576,64,3,176,64,3,352,6,3,352,120,1,300,64,1,436,32,1,436,96,3,500,50,3,500,78,\""
      "},"
      ""
      "{"
      "ref=\"64,74,true,\","
      "tiles=\"1,-1,\","
      "ferns=\"8,112,2,3,32,120,2,3,104,120,3,3,112,112,3,3,\","
      "spawn=\"0,64,64,3,20,108,3,108,108,3,108,20,3,20,20,\""
      "},"
      ""
      ""
      "{"
      "ref=\"192,192,\","
      "tiles=\"19,4,20,-1,27,21,12,-1,3,4,28,-1,\","
      "ferns=\"199,232,3,9,206,232,3,9,99,224,2,15,106,224,3,15,32,184,2,9,215,104,3,9,230,104,3,15,237,104,2,9,360,224,3,15,368,208,2,15,70,352,2,9,80,352,4,9,90,352,5,15,100,352,7,9,110,360,10,9,120,360,8,9,130,360,9,15,140,360,7,9,150,360,10,9,160,360,10,9,170,352,8,9,180,352,5,9,190,352,9,9,200,352,7,9,210,360,6,9,220,360,7,9,230,360,8,9,240,360,6,15,250,360,4,9,260,360,7,9,270,360,8,9,280,336,7,9,290,336,8,9,300,336,6,15,310,344,5,9,320,336,8,9,330,336,6,15,\","
      "spawn=\"0,32,320,4,95,160,4,210,32,4,350,210,3,290,295,3,310,295,8,80,320,8,64,296,8,64,344,\","
      "},"
      ""
      "{"
      "ref=\"64,74,true,\","
      "tiles=\"1,-1,\","
      "spawn=\"0,64,64,4,64,20,4,28,100,4,100,100,\","
      "ferns=\"8,112,5,9,32,120,6,9,104,120,4,9,112,112,3,9,16,120,5,9,51,120,3,9,77,120,3,15,84,120,5,9,\","
      "},"
      ""
      "{"
      "ref=\"64,192,\","
      "tiles=\"18,0,3,4,20,-1,7,0,16,17,12,-1,17,9,17,24,28,-1,\","
      "ferns=\"164,266,5,14,196,272,6,12,220,256,5,14,260,248,7,12,120,120,3,12,502,104,4,12,509,104,3,14,604,280,4,14,480,352,6,14,488,352,5,12,502,360,5,12,\","
      "spawn=\"0,454,314,5,170,64,5,200,128,5,230,196,5,368,80,5,392,20,5,416,80,5,562,178,5,576,60,5,590,228,5,486,320,\""
      "},"
      ""
      "{"
      "ref=\"64,74,true,\","
      "tiles=\"1,-1,\","
      "ferns=\"24,120,2,12,34,120,1,14,74,120,4,12,94,120,3,14,104,120,2,14,\","
      "spawn=\"0,64,64,5,32,96,5,96,32,8,32,32,8,96,96,\","
      "},"
      ""
      "{"
      "ref=\"26,64,\","
      "tiles=\"3,4,4,5,4,6,21,-1,\","
      "ferns=\"104,104,3,13,111,104,2,5,125,104,2,13,132,104,4,5,139,104,3,5,152,104,2,13,226,104,3,5,258,104,2,13,354,104,4,5,386,104,2,5,426,104,3,13,433,104,2,5,440,104,3,13,500,104,2,13,520,104,3,13,670,40,3,5,680,40,3,13,690,40,2,13,700,40,1,5,710,40,2,13,720,40,3,13,730,40,2,5,670,112,1,13,680,112,2,13,690,112,2,5,700,112,3,13,710,112,2,13,720,112,2,5,730,112,2,13,\","
      "spawn=\"0,820,64,6,246,102,6,438,102,1,472,60,6,512,102,5,656,48,5,748,48,6,692,112,6,692,40,\""
      "},"
      ""
      "{"
      "ref=\"128,176,true,\","
      "tiles=\"19,20,-1,27,28,-1,\","
      "ferns=\"40,200,4,13,72,208,2,5,96,224,3,13,104,224,2,5,120,232,4,13,128,232,5,5,136,232,3,13,144,232,4,13,156,208,2,13,166,208,3,5,180,216,3,5,192,208,3,5,224,152,5,13,\","
      "spawn=\"0,128,48,6,56,200,6,184,216,6,128,104,1,120,88,1,136,88,\""
      "},"
      ""
      "{"
      "tiles=\"24,4,21,-1,\","
      "spawn=\"0,320,64,7,256,56,7,256,72,\","
      "ferns=\"192,96,2,8,304,112,2,9,320,104,2,8,\""
      "},"
      ""
      "{"
      "ref=\"82,64,\","
      "tiles=\"24,4,7,0,-1,17,17,18,0,-1,17,17,18,0,-1,17,17,17,15,-1,\","
      "spawn=\"0,450,500,5,140,30,4,240,64,5,338,64,6,376,246,6,390,382,5,400,60,5,432,120,5,464,260,5,496,160,\","
      "fields=\"194,42,3,1,80,0,true,234,88,3,1,80,0,true,408,12,1,3,0,135,true,478,66,1,4,0,82,true,448,102,1,5,0,60,true,426,412,3,2,25,20,true,\","
      "triggers={{"
      "{},"
      "function()"
      "local m=create_mine(130,74)"
      "m.state=\"detonate\""
      "end"
      "}}"
      "},"
      ""
      "{"
      "tiles=\"7,2,0,3,20,17,-1,25,9,9,17,11,17,-1,0,3,20,18,0,16,-1,9,17,13,17,15,17,-1,17,17,27,5,28,17,-1,\","
      "ferns=\"24,96,2,8,72,96,3,8,79,96,2,2,96,96,2,14,280,128,2,8,288,136,3,2,312,136,4,8,320,144,4,8,328,144,5,14,460,96,2,8,467,96,2,8,544,440,3,8,608,440,4,2,456,584,3,8,463,584,2,8,470,584,3,14,477,584,3,8,484,584,2,2,320,584,3,8,328,592,3,14,286,480,4,8,294,480,3,8,302,480,3,2,310,480,2,8,318,480,3,8,70,400,5,8,80,384,4,14,26,384,4,8,\","
      "spawn=\"0,64,300,7,240,20,6,300,136,7,425,70,4,335,89,1,564,460,1,580,460,1,596,460,11,344,392,1,297,309,1,208,343,1,116,300,1,24,332,3,348,350,3,172,289,3,60,360,7,530,336,7,660,336,7,400,570,8,468,570,8,308,470,\""
      "},"
      ""
      "{"
      "tiles=\"24,5,5,5,20,-1,19,6,6,6,28,-1,27,5,5,5,21,-1,24,6,6,6,21,-1,\","
      "spawn=\"0,576,320,3,240,62,2,343,62,2,460,62,1,480,62,6,186,168,6,314,168,6,442,168,4,240,318,2,343,318,2,460,318,1,480,318,6,170,424,6,202,424,6,298,424,6,330,424,6,426,424,6,458,424,\","
      "ferns=\"\".."
      "\"384,232,4,8,392,240,5,14,400,240,4,8,408,240,3,8,416,240,3,14,424,240,3,8,432,240,3,14,440,240,3,8,448,240,3,8,456,240,3,14,464,240,3,14,472,240,3,8,480,240,4,14,488,240,4,14,496,240,5,8,504,232,5,14,256,232,6,2,264,240,4,2,272,240,4,2,280,240,3,8,288,240,3,8,296,240,3,2,304,240,3,8,312,240,3,8,320,240,3,14,328,240,3,2,336,240,3,8,344,240,3,8,352,240,6,14,360,240,4,8,368,240,5,8,376,232,5,14,128,232,3,2,136,240,4,2,144,240,4,8,152,240,3,2,160,240,3,8,168,240,3,8,176,240,3,2,184,240,3,8,192,240,3,8,200,240,3,2,208,240,3,8,216,240,3,2,224,240,4,2,232,240,4,8,240,240,5,8,248,232,6,8,\","
      "},"
      ""
      "{"
      "ref=\"192,32,\","
      "tiles=\"17,12,17,-1,17,11,17,-1,18,0,16,-1,18,0,16,-1,17,15,17,-1,\","
      "spawn=\"0,192,620,4,192,128,4,202,292,7,158,388,7,230,388,4,196,464,\","
      "fields=\"169,120,4,1,18,0,false,140,312,8,2,18,128,false,\""
      "},"
      ""
      "{"
      "ref=\"32,192,\","
      "tiles=\"17,18,0,0,16,-1,4,7,0,0,16,-1,17,18,0,0,3,-1,17,17,9,9,17,-1,\","
      "fields=\"264,8,5,6,64,64,false,\","
      "ferns=\"88,232,3,8,104,232,2,9,112,232,3,8,152,224,3,9,168,224,2,9,176,232,3,8,\","
      "spawn=\"0,608,320,5,296,32,5,360,64,5,424,250,5,488,128,8,296,104,8,400,168,8,480,232,8,312,296,8,312,360,5,296,160,5,360,192,5,424,122,5,488,256,8,424,104,8,300,168,8,380,232,8,512,296,8,412,360,\""
      "},"
      ""
      "{"
      "tiles=\"15,-1,12,-1,13,-1,12,-1,11,-1,0,-1,2,-1,29,-1,0,-1,\","
      "spawn=\"0,64,1088,\","
      "fields=\"50,82,2,4,38,52,true,68,108,1,4,38,52,true,50,402,2,6,38,52,true,68,428,1,6,38,52,true,\","
      "triggers={{"
      "parse\"64,840,60,10,0,\","
      "function() create_trap(96,882) end"
      "},{"
      "parse\"64,928,60,10,0,\","
      "function() create_trap(20,960) create_trap(108,930)end"
      "}}"
      "},"
      ""
      "{"
      "tiles=\"0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,\","
      "spawn=\"0,64,875,\","
      "inks=\"90,110,110,120,26,166,40,190,95,226,128,260,0,316,72,346,50,400,128,430,0,540,74,600,0,600,88,640,60,680,80,700,90,690,120,720,0,820,128,840,0,860,20,896,106,880,128,896,\""
      "},"
      ""
      "{"
      "tiles=\"0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,\","
      "spawn=\"0,64,875,\","
      "inks=\"0,100,128,132,0,200,128,256,0,320,128,352,48,352,128,452,48,452,80,500,0,500,80,664,80,564,128,600,54,664,128,732,0,732,128,780,40,780,128,854,84,854,128,896,\""
      "},"
      ""
      "{"
      "ref=\"54,140,false,\","
      "tiles=\"25,25,25,25,25,25,25,-1,0,0,0,0,0,0,0,-1,0,0,0,0,0,0,0,-1,0,0,26,26,26,26,26,-1,10,8,30,31,30,31,30,-1,\","
      "spawn=\"0,120,616,\","
      "inks=\"-10,192,800,384,880,176,900,560,500,172,530,404,364,440,412,460,-10,-10,20,512,96,436,140,486,214,480,264,616,-10,500,64,564,280,360,296,440,\","
      "triggers={{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "update_boss()"
      "if t%150==0 or t==20 then"
      "boss.wave=40"
      "music(3)"
      "for i=296,872,64 do"
      "create_bubbles(i,436,16,14,2,4)"
      "end"
      "end"
      "end"
      "}}"
      "},"
      ""
      "{"
      "ref=\"64,32,\","
      "tiles=\"22,-1,22,-1,30,-1,23,-1,31,-1,\","
      "spawn=\"0,240,128,6,-15,650,6,138,650,6,-15,512,6,138,512,\","
      "triggers={{"
      "{},"
      "function()"
      "change_state(boss,\"active\")"
      "boss.hp=3"
      "create_bubbles(arg\"64,320,20,40,2,3,\")"
      "create_ink(arg\"-20,320,146,340,13,true,\")"
      "boss.wave=40"
      "music(3)"
      "end"
      "},{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "update_boss()"
      "end"
      "}}"
      "},"
      ""
      "{"
      "ref=\"192,704,\","
      "tiles=\"17,15,17,-1,17,12,17,-1,17,12,17,-1,17,11,17,-1,18,2,16,-1,18,0,16,-1,\","
      "spawn=\"0,192,32,1,190,346,1,202,442,6,78,64,6,78,128,6,78,192,6,306,64,6,306,128,6,306,192,\","
      "fields=\"176,322,2,8,40,24,false,191,252,4,1,12,0,false,\","
      "triggers={{"
      "{},"
      "function()"
      "create_ink(arg\"-10,768,394,768,13,\")"
      "end"
      "},{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "if t%2==0 then"
      "create_explosion(rnd(328)+120,rnd(256)+512,rnd(8)+8)"
      "create_explosion(rnd(128)+128,rnd(512),rnd(8)+8)"
      "end"
      "if t%flr(rnd(10)+4)==0 then sfx(14) add_shake(4) end"
      "end"
      "}}"
      "},"
      ""
      "{"
      "ref=\"64,1088,\","
      "tiles=\"0,-1,0,-1,15,-1,12,-1,12,-1,13,-1,12,-1,11,-1,15,-1,\","
      "spawn=\"0,64,32,6,-12,640,6,140,640,\","
      "fields=\"30,510,6,1,10,0,false,70,456,5,1,10,0,false,28,80,3,3,40,80,true,48,120,2,3,40,80,true,\","
      "triggers={{"
      "{},"
      "function()"
      "create_ink(arg\"-10,1150,138,1152,13,\")"
      "create_trap(40,1020)"
      "create_trap(94,1020)"
      "end"
      "},{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "if t%4==0 then"
      "create_explosion(rnd(128),rnd(512)+248,rnd(8)+8)"
      "create_explosion(rnd(128),rnd(512)+760,rnd(8)+8)"
      "end"
      "if t%flr(rnd(10)+4)==0 then sfx(14) add_shake(4) end"
      "end"
      "},{"
      "parse\"64,388,60,45,0,\","
      "function()"
      "create_trap(28,214)"
      "create_trap(100,214)"
      "end"
      "}}"
      "},"
      ""
      "{"
      "ref=\"276,64,\","
      "tiles=\"14,4,-1,\","
      "spawn=\"0,300,150,\","
      "ferns=\"0,104,3,8,8,104,2,9,32,112,2,8,40,112,1,2,49,128,2,8,56,128,3,14,91,128,2,8,104,120,4,2,112,104,4,8,121,104,6,14,128,104,6,8,135,104,5,9,142,104,4,10,149,104,3,15,156,104,2,7,218,104,2,7,225,104,3,15,232,104,4,10,239,104,5,9,246,104,6,8,\","
      "triggers={{"
      "{},"
      "function()"
      "player.off=true"
      "end"
      "},{"
      "parse\"0,0,0,0,1,\","
      "function()"
      "if titles then"
      "player.off=true"
      "player.dir=7"
      "if t==80 then music(2) end"
      "if t>=30 and t<=200 then"
      "change_state(player,\"swim\")"
      "player.vx-=0.3"
      "player.vy-=0.3"
      "end"
      "else"
      "if t==20 then"
      "create_explosion(arg\"250,64,30,\")"
      "sfx(14)"
      "add_shake(2)"
      "music(0)"
      "player.dir=6"
      "player.vx=-4"
      "end"
      "if t==60 then player.off=false end"
      "end"
      "end"
      "},{"
      "parse\"72,64,30,0,0,\","
      "function()"
      "titles=true"
      "t=0"
      "end"
      "}}"
      "}"
      ""
      "}"
      "end"
      ""
      "-->8"
      "--game loop"
      ""
      "function _init()"
      ""
      "load_room_data()"
      ""
      "room=1"
      "godmode = false"
      ""
      "wtrfrc = 0.94"
      ""
      "gt,gm,deathcounter,freeze,fade=0,0,0,0,0"
      ""
      "camx,camy,shkx,shky = 0,0,0,0"
      ""
      "fades={"
      "0b1111111111111111.1,"
      "0b0111111111011111.1,"
      "0b0101111101011111.1,"
      "0b0101101101011110.1,"
      "0b0101101001011010.1,"
      "0b0001101001001010.1,"
      "0b0000101000001010.1,"
      "0b0000001000001000.1"
      "}"
      ""
      "boss = {"
      "x=52,"
      "y=592,"
      "hp=3,"
      "animt=0,"
      "state=\"dead\","
      "wave=0,"
      "box = new_box(arg\"48,576,80,608,\")"
      "}"
      ""
      "load_room(room)"
      "end"
      ""
      "function _update()"
      "t+=1"
      "if t>=30000 then t=0 end"
      "if room>1 and room <#rooms then"
      "gt+=1"
      "if gt==1800 then gt=0 gm+=1 end"
      "end"
      "if freeze >0 then freeze -= 1 return end"
      "if fade>0 then return end"
      ""
      "update_shake()"
      "update_player(player)"
      "update_objects(objects)"
      "update_hazards(hazards)"
      "update_particles()"
      "update_exit()"
      ""
      "if (player.invinci<=0 and not godmode) or player.state==\"attack\" then"
      "coll_objs()"
      "check_hazard_colls(hazards)"
      "end"
      "coll_exit()"
      ""
      ""
      "update_camera()"
      ""
      "for enemy in all(objects) do"
      "if enemy.name!=\"pearl\" and enemy.name!=\"clam\" then"
      "detectwalls(enemy)"
      "end"
      "end"
      ""
      "update_triggers(triggers)"
      "end"
      ""
      ""
      "function _draw()"
      ""
      "if fade>0 then"
      "if fade<=#fades and fadein==false then"
      "fillp(fades[fade])"
      "rectfill(0,0,cmaxx,cmaxy,1)"
      "fade+=1"
      "fillp()"
      "return"
      "else"
      "fadein=true"
      "end"
      "end"
      ""
      "cls()"
      ""
      "camera(camx,camy)"
      ""
      "draw_background()"
      "draw_foreground()"
      "draw_exit()"
      "draw_particles()"
      "draw_hazards(hazards)"
      "draw_objects(objects)"
      "draw_player(player)"
      "draw_fx(fx)"
      ""
      "if boss.state!=\"dead\" then draw_boss() end"
      ""
      "if room>1 and room<#rooms then"
      "draw_hud()"
      "else"
      "draw_titles()"
      "end"
      ""
      "camera()"
      ""
      "if fadein  then"
      "fade-=1"
      "if fade>0 then"
      "fillp(fades[fade])"
      "rectfill(0,0,cmaxx,cmaxy,1)"
      "fillp()"
      "else"
      "fade=0"
      "fadein=false"
      "end"
      "end"
      "end"
      ""
      ""
      ""
      "function update_camera()"
      "local xoff,yoff,pd = 0,0,player.dir"
      "if pd >= 1 and pd <=3 then xoff = 12 end"
      "if pd >= 5 and pd <=7 then xoff = -12 end"
      "if pd <=1 or pd ==7 then yoff = -12 end"
      "if pd >= 3 and pd <=5 then yoff = 12 end"
      "local xpoint = max(0,player.x-64+(player.vx*14)+xoff)"
      "local ypoint = max(0,player.y-64+(player.vy*14)+yoff)"
      "camx += (xpoint-camx)*0.1"
      "camy += (ypoint-camy)*0.1"
      "if camx>cmaxx-127 then camx=cmaxx-127 end"
      "if camy>cmaxy-127 then camy=cmaxy-127 end"
      "camx +=shkx"
      "camy +=shky"
      "end"
      ""
      ""
      "function draw_background()"
      "rectfill(0,0,cmaxx,cmaxy,1)"
      "end"
      ""
      ""
      "function draw_foreground()"
      "local mapx,mapy = 0,0"
      "pal(10,0)"
      "for i in all(roomtiles) do"
      "if i == -1 then"
      "mapx=0"
      "mapy+=128"
      "else"
      "map((i%8)*16,flr(i/8)*16,mapx,mapy,16,16,0x1)"
      "mapx+=128"
      "end"
      "end"
      "pal()"
      "end"
      ""
      "function update_objects(objects)"
      "for enemy in all(objects) do"
      "enemy.update(enemy)"
      "end"
      "end"
      ""
      "function update_hazards(hazards)"
      "for p in all(hazards) do"
      "p.update(p)"
      "end"
      "end"
      ""
      "function check_hazard_colls(hazards)"
      "for p in all(hazards) do"
      "p.coll(p)"
      "end"
      "end"
      ""
      "function draw_hazards(hazards)"
      "for p in all(hazards) do"
      "p.draw(p)"
      "end"
      "end"
      ""
      ""
      ""
      "function create_trigger(ref,exec)"
      "local t ={"
      "x=ref[1] or 0,"
      "y=ref[2] or 0,"
      "prox=ref[3] or 1,"
      "t=ref[4] or 0,"
      "active=ref[5] or 1,"
      "exec=exec"
      "}"
      "add(triggers,t)"
      "end"
      ""
      "function update_triggers(triggers)"
      "for trig in all(triggers) do"
      "local kill=false"
      "if trig.prox>0 then"
      "kill=true"
      "if dist(player.x,player.y,trig.x,trig.y)<=trig.prox then"
      "trig.active=1"
      "end"
      "end"
      ""
      "if trig.active==1 then"
      "if trig.t>0 then"
      "trig.t-=1"
      "else"
      "trig.t = 0"
      "trig.exec()"
      "if kill then del(triggers,trig) end"
      "end"
      "end"
      "end"
      "end"
      ""
      "function update_shake()"
      "if abs(shkx)+abs(shky)<0.5 then"
      "shkx,shky=0,0"
      "else"
      "shkx*=-0.5-rnd(0.2)"
      "shky*=-0.5-rnd(0.2)"
      "end"
      "end"
      ""
      "function draw_objects(objects)"
      "for enemy in all(objects) do"
      "enemy.draw(enemy)"
      "end"
      "end"
      ""
      "function draw_hud()"
      "for i=106,122,8 do"
      "circ(camx+i-shkx,camy+6-shky,3.5,0)"
      "end"
      "local cx=106"
      "local col=ternary(t<30 and t%4==0,7,8)"
      "for i=1,player.hp do"
      "circfill(camx+cx-shkx,camy+6-shky,2.5,col)"
      "pset(camx+cx-1-shkx,camy+4-shky,7)"
      "cx+=8"
      "end"
      ""
      "boldprint(timer(),camx+2-shkx,camy+121-shky)"
      "end"
      ""
      "function draw_titles()"
      "if player.y>=60 and t>=60 and room==1 then"
      "boldprint(\"⬅️➡️⬆️⬇️: move\",32,40)"
      "boldprint(\"❎/🅾️ (hold): attack\",20,50)"
      "end"
      "if titles and t>=80 then"
      "if room==1 then"
      "boldprint(\"s w o r d f i s h\",155,60)"
      "else"
      "local tstars, dstars = 1,1"
      "if gm <15 then"
      "tstars = 2"
      "if gm<10 then"
      "tstars = 3"
      "end"
      "end"
      "if deathcounter <11 then"
      "dstars=2"
      "if deathcounter <6 then"
      "dstars=3"
      "end"
      "end"
      ""
      "rect(arg\"28,27,96,96,\")"
      "boldprint(\"congratulations\",33,32,10)"
      "boldprint(\"time: \"..timer(),43,42)"
      ""
      "for i=1,3 do"
      "local sx = 40+(i*10)"
      "if i>tstars then"
      "print(\"★\",sx,52,6)"
      "else"
      "boldprint(\"★\",sx,52,10)"
      "end"
      "end"
      ""
      "boldprint(\"deaths: \"..deathcounter,45,62)"
      ""
      "for i=1,3 do"
      "local sx = 40+(i*10)"
      "if i>dstars then"
      "print(\"★\",sx,72,6)"
      "else"
      "boldprint(\"★\",sx,72,10)"
      "end"
      "end"
      ""
      "boldprint(\"thanks for\",43,82)"
      "boldprint(\"playing!\",48,89)"
      "end"
      "end"
      "end"
      ""
      "function draw_fx(fxs)"
      "for fx in all(fx) do"
      "fx.draw(fx)"
      "end"
      "end"
      ""
      "function next_room()"
      "room+=1"
      "load_room(room)"
      "end"
      ""
      ""
      "function load_room(rm)"
      "t=0"
      ""
      "objects={}"
      "fx={}"
      "particles={}"
      "triggers={}"
      "hazards={}"
      ""
      "local r=rooms[rm]"
      ""
      "local roomref={64,64,false}"
      "if r.ref then roomref=parse(r.ref) end"
      ""
      "local px = roomref[1]"
      "local py = roomref[2]"
      "player = create_player(px,py)"
      "camx=max(0,px-54)"
      "camy=max(0,py-64)"
      ""
      "roomtiles=parse(r.tiles)"
      "roomrows = 0"
      "for i in all(roomtiles) do"
      "if i == -1 then"
      "roomrows+=1"
      "end"
      "end"
      ""
      "roomcols = (#roomtiles-roomrows)/roomrows"
      ""
      "cmaxx = roomcols*128-1"
      "cmaxy = roomrows*128-1"
      ""
      "spawnlist(r.spawn)"
      ""
      "if roomref[3] then"
      "exit.state=\"closed\""
      "exit.combat=true"
      "end"
      ""
      "for t in all(r.triggers) do"
      "create_trigger(t[1],t[2])"
      "end"
      ""
      "if r.fields!=nil then"
      "local f = parse(r.fields)"
      "for i=1,#f,7 do"
      "create_field(f[i],f[i+1],f[i+2],f[i+3],f[i+4],f[i+5],f[i+6])"
      "end"
      "end"
      ""
      "if r.inks!=nil then"
      "local inks = parse(r.inks)"
      "for i=1,#inks,4 do"
      "create_ink(inks[i],inks[i+1],inks[i+2],inks[i+3])"
      "end"
      "end"
      ""
      "if r.ferns!=nil then"
      "local fs = parse(r.ferns)"
      "for i=1,#fs,4 do"
      "create_fern(fs[i],fs[i+1],fs[i+2],fs[i+3])"
      "end"
      "end"
      ""
      "fade=1"
      ""
      "end"
      ""
      ""
      "-->8"
      "--player--"
      ""
      "function create_player(x,y)"
      "local p=new_object(x,y,\"player\")"
      "p.dir=2"
      "p.hp=3"
      "p.charge=0"
      "p.invinci=0"
      "p.cooldown=0"
      "p.flash=0"
      "p.bigbox=false"
      "p.tpspd = 3"
      ""
      "p.spr_info={"
      "idle = {"
      "up = parse\"7,38,7,39,\","
      "diagu = parse\"32,36,32,34,\","
      "diagd = parse\"40,42,40,44,\","
      "right=parse\"16,18,16,20,\","
      "dt=0.3"
      "},"
      "swim = {"
      "up = parse\"38,39,\","
      "diagu = parse\"36,34,\","
      "diagd = parse\"42,44,\","
      "right=parse\"18,20,\","
      "dt=0.05"
      "},"
      "charge = {"
      "up = {38},"
      "diagu = {32},"
      "diagd = {42},"
      "right={18},"
      "dt=0.2"
      "},"
      "attack = {"
      "up = {15},"
      "diagu = {11},"
      "diagd = {11},"
      "right={13},"
      "dt=0.2"
      "},"
      "hurt = {"
      "hurt = {46},"
      "dt=0.2"
      "},"
      "dead = {"
      "hurt = {46},"
      "dt=0.2"
      "}"
      "}"
      "p.abs_box=function(att)"
      "local b,mx,my,pb = 5,0,0,p.bigbox and att"
      "if att and p.state==\"attack\" then"
      "b=ternary(pb,14,8)"
      "end"
      ""
      "if p.dir== 0 or p.dir==4 then"
      "mx=1"
      "if pb then"
      "my=5"
      "end"
      "elseif p.dir==2 or p.dir==6 then"
      "my=1"
      "if pb then"
      "mx=5"
      "end"
      "elseif pb then"
      "mx,my=5,5"
      "end"
      ""
      "return new_box(p.x-b+mx,p.y-b+my,p.x+b-mx,p.y+b-my)"
      "end"
      ""
      "return p"
      "end"
      ""
      ""
      "function update_player(p)"
      "p.animt+=0.01"
      ""
      "local state = p.state"
      ""
      "if state==\"dead\" then"
      "p.vy+=0.04"
      "apply_friction(p,wtrfrc)"
      "if abs(p.animt/0.01)%2==0 then p.flash = 0.1 end"
      "if p.animt>=1 then load_room(room) end"
      ""
      "else"
      ""
      "if p.invinci>0 then"
      "p.invinci -= 1"
      "else p.invinci = 0"
      "end"
      "local bl,br,bu,bd,bx,bz"
      "if not player.off then"
      "if btn\"0\" then bl=true end"
      "if btn\"1\" then br=true end"
      "if btn\"2\" then bu=true end"
      "if btn\"3\" then bd=true end"
      "if btn\"4\" then bz=true end"
      "if btn\"5\" then bx=true end"
      "end"
      "if state==\"hurt\" then"
      "if p.cooldown > 0 then"
      "bl,br,bu,bd = false, false, false, false"
      "else"
      "p.invinci = 60"
      "change_state(p,\"idle\")"
      "end"
      "end"
      "if p.cooldown > 0 then"
      "p.cooldown-=0.1"
      "bz,bx = false,false"
      "else"
      "p.cooldown=0"
      "end"
      "if state==\"charge\"and not(bz or bx) then"
      "if p.charge>=1 then"
      "sfx(4)"
      "create_bubbles(p.x,p.y,rnd(4)+p.charge,4,1,p.charge+1)"
      "if p.charge>=3 then p.bigbox=true end"
      "change_state(p,\"attack\")"
      "else"
      "change_state(p,'idle')"
      "end"
      "end"
      "state = p.state"
      "if state==\"attack\" then"
      "if p.charge > 0 then"
      "local d = p.dir"
      "local attackspd=8"
      "if d==0 or d==1 or d==7 then p.vy-=attackspd end"
      "if d>=1 and d<=3 then p.vx+=attackspd end"
      "if d>=3 and d<=5 then p.vy+=attackspd end"
      "if d>=5 then p.vx-=attackspd end"
      "p.charge-=0.15"
      "apply_accel(p,p.tpspd+(flr(p.charge)*1.5))"
      "if abs(p.animt/0.01)%2==0 then\tp.flash = 0.1 end"
      "add_shake(0.3)"
      "else"
      "p.charge = 0"
      "p.cooldown = 2"
      "if player.invinci<3 then player.invinci=15 end"
      "p.bigbox = false"
      "change_state(p,'idle')"
      "end"
      "else"
      "if (state==\"charge\" and t%3==0) or state!=\"charge\" then --only check direction every three frames if charging( to make aiming less fiddly)"
      "setdirection(p,bl,br,bu,bd)"
      "end"
      "if (bl or br or bu or bd) and not(bz or bx) then"
      "local placc=0.5"
      "change_state(p,\"swim\")"
      "if bl then p.vx-=placc end"
      "if br then p.vx+=placc end"
      "if bu then p.vy-=placc end"
      "if bd then p.vy+=placc end"
      "apply_accel(p,p.tpspd)"
      "else"
      "if (bz or bx) and not (p.cooldown >0) then"
      "change_state(p,\"charge\")"
      "if p.animt>=0.8 then"
      "p.charge = 0"
      "sfx(5)"
      "add_shake(3)"
      "p.cooldown = 2"
      "change_state(p,'idle')"
      "elseif p.animt>=0.27 and p.charge <3 then"
      "p.charge=3"
      "sfx(3)"
      "elseif p.animt>=0.15 and p.charge <2 then"
      "p.flash=0.2"
      "p.charge=2"
      "sfx(2)"
      "elseif p.animt>=0.03 and p.charge <1 then"
      "p.flash=0.2"
      "p.charge=1"
      "sfx(1)"
      "end"
      "if p.charge==3 and abs(p.animt/0.01)%5==0 and p.animt<0.75 then"
      "p.flash = 0.2"
      "end"
      ""
      "elseif state!='hurt' and not titles then"
      "change_state(p,\"idle\")"
      "end"
      "end"
      "end"
      "end"
      "if state==\"attack\" then"
      "local xm=0.3"
      ""
      "if p.dir%2!=0 then xm=-0.3 end"
      "create_particle(p.x+p.vx*2.2,p.y+p.vy*2.2,p.vy*0.3,p.vx*xm,true)"
      "create_particle(p.x+p.vx*2.2,p.y+p.vy*2.2,p.vy*-0.3,p.vx*-xm,true)"
      "end"
      "apply_friction(p,wtrfrc)"
      "move(p)"
      "if not player.off then"
      "detectwalls(p)"
      "end"
      "end"
      ""
      "function draw_player(p)"
      "local state=p.state"
      "local sinfo=p.spr_info[state]"
      "local flipx,flipy,sprw,sprh,xoff,yoff,sprites = false,false,2,2,-4,-8,{}"
      ""
      "if state==\"hurt\" or state==\"dead\" then"
      "sprites = sinfo.hurt"
      "else"
      "local d = p.dir"
      "if d==0 or d==4 then sprites = sinfo.up sprw=1 end"
      "if d==1 or d==7 then sprites = sinfo.diagu xoff=-8 end"
      "if d==2 or d==6 then sprites = sinfo.right sprh=1 xoff=-8 yoff=-4 end"
      "if d==3 or d==5 then sprites = sinfo.diagd xoff=-8 end"
      "if d==4 or ((d==3 or d==5) and state==\"attack\") then flipy=true end"
      "if d>=5 then flipx=true end"
      "end"
      "local spri = sprites[flr(p.animt/sinfo.dt)%#sprites+1]"
      "if (p.invinci>0 and flr(p.invinci%3)==0) then"
      "else"
      "local fc = 7"
      "if state==\"dead\" then fc=8 end"
      "local oc = 0"
      "if p.flash>0 then oc = fc end"
      "drawoutline(spri,p.x+xoff,p.y+yoff,sprw,sprh,flipx,flipy,oc)"
      "flashobject(p,fc)"
      "spr(spri,p.x+xoff,p.y+yoff,sprw,sprh,flipx,flipy)"
      "end"
      "pal()"
      "end"
      ""
      "function coll_objs()"
      "for e in all(objects) do"
      ""
      "local att=ternary(player.state==\"attack\" and not e.invinci,true,false)"
      ""
      ""
      "if coll(e.abs_box(),player.abs_box(att)) then"
      "local name = e.name"
      "if name==\"mine\" then change_state(e,\"detonate\") sfx(9)end"
      ""
      "if player.state==\"attack\" then"
      "if e.invinci then"
      "if player.invinci>0 then return end"
      "if name!=\"clam\" then bounce(e,player.vx*0.6,player.vy*0.6) end"
      "cancel_attack()"
      "bounce_relative(player,e,3)"
      "else"
      "kill_object(e)"
      "end"
      "elseif player.state!=\"hurt\" then"
      "if name!=\"clam\" then bounce(e,player.vx,player.vy) end"
      "if name!=\"mine\" then"
      "if not (name==\"clam\" and e.state==\"idle\") then"
      "if player.invinci>0 then return end"
      "hurt_player(player)"
      "end"
      "end"
      "bounce_relative(player,e,3)"
      "if name==\"pearl\" then kill_object(e) end"
      "end"
      "end"
      "end"
      "end"
      ""
      ""
      "function hurt_player(p)"
      "if p.state != \"dead\" then"
      "p.hp-=1"
      "create_bubbles(p.x,p.y,rnd(3)+3,8,2,4)"
      "freeze=3"
      "sfx(6)"
      "add_shake(10)"
      "if p.hp<=0 then"
      "deathcounter+=1"
      "change_state(p,\"dead\")"
      "else"
      "p.charge = 0"
      "p.cooldown = 3"
      "change_state(p,\"hurt\")"
      "end"
      "end"
      "end"
      ""
      "function cancel_attack()"
      "change_state(player,\"idle\")"
      "add_shake(3)"
      "sfx(9)"
      "player.charge = 0"
      "player.cooldown = 2"
      "player.flash = 0"
      "player.bigbox=false"
      "for i=1,rnd(4)+3 do"
      "create_particle(player.x,player.y,rnd(3)+-2,rnd(3)+-2,true)"
      "end"
      "if player.invinci<3 then player.invinci=15 end"
      "end"
      ""
      "-->8"
      "--objects--"
      ""
      ""
      "function new_object(x,y,name,update,draw)"
      "return {x=x,y=y,vx=0,vy=0,animt=0,state=\"idle\",name=name,update=update,draw=draw}"
      "end"
      ""
      "function create_snapper(x,y)"
      "local e=new_object(x,y,\"snapper\",update_snapper,draw_snapper)"
      "e.dir=0"
      "e.active=false"
      ""
      "e.spr_info={"
      "idle = {"
      "up = {1,2},"
      "diag = {3,4},"
      "right={5,6},"
      "dt=0.02"
      "}"
      "}"
      "e.abs_box=function()"
      "return new_box(e.x-3,e.y-3,e.x+3,e.y+3)"
      "end"
      "add(objects, e)"
      "return e"
      "end"
      ""
      "function create_school(x,y)"
      "for i=1,6 do"
      "local a=rnd(1)"
      "local d=rnd(20)"
      "local sx=x+d*cos(a)"
      "local sy=y+d*sin(a)"
      "create_snapper(sx,sy)"
      "end"
      "end"
      ""
      ""
      "function update_snapper(e)"
      "e.animt+=0.01"
      "local d = dist(e.x,e.y,player.x,player.y)"
      "if not e.active then"
      "if d<=120 then e.active=true end"
      "else"
      "local spd,buff=0.1,20"
      "if d<=20 then buff=4 end"
      "local l,r,u,d"
      "if player.x-buff > e.x then e.vx +=spd r=true end"
      "if player.x+buff < e.x then e.vx -=spd l=true end"
      "if player.y-buff > e.y then e.vy +=spd d=true end"
      "if player.y+buff < e.y then e.vy -=spd u=true end"
      "apply_accel(e,1)"
      "setdirection(e,l,r,u,d)"
      ""
      "move(e)"
      "end"
      "end"
      ""
      "function draw_snapper(e)"
      "local sinfo,flipx,flipy,sprites,d=e.spr_info[e.state],false,false,{},e.dir"
      ""
      "if d==0 or d==4 then sprites = sinfo.up  end"
      "if d==1 or d==3 or d==5 or d==7 then sprites = sinfo.diag end"
      "if d==2 or d==6 then sprites = sinfo.right end"
      "if d>=3 and d<=5 then  flipy=true end"
      "if d>=5 then flipx=true end"
      ""
      "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
      "drawoutline(spri,e.x-4,e.y-4,1,1,flipx,flipy,0,true)"
      "end"
      ""
      "function create_puffer(x,y)"
      "local e=new_object(x,y,\"puffer\",update_puffer,draw_puffer)"
      "e.invinci=false"
      ""
      "e.spr_info={"
      "idle = {"
      "sprites = {110,111},"
      "dt=0.02"
      "},"
      "puffed = {"
      "sprites = {78},"
      "dt=0.5"
      "}"
      "}"
      "e.abs_box=function()"
      "local size = ternary(e.state==\"puffed\",7,3)"
      "return new_box(e.x-size,e.y-size,e.x+size,e.y+size)"
      "end"
      "add(objects, e)"
      "return e"
      "end"
      ""
      ""
      "function update_puffer(e)"
      "e.animt+=0.01"
      "local os= is_offscreen(e,80)"
      "if os then return end"
      "local state = e.state"
      "local spd = ternary(state==\"puffed\",0.06,0.1)"
      ""
      "if e.animt>1.2 and state==\"idle\" then"
      "change_state(e,\"puffed\")"
      "e.invinci=true"
      "if not os then sfx(23) end"
      "end"
      "if e.animt>0.75 and state==\"puffed\" then"
      "change_state(e,\"idle\")"
      "e.invinci=false"
      "if not os then sfx(24) end"
      "end"
      "if dist(player.x,player.y,e.x,e.y)<48 and state==\"idle\" then spd *=-1 end"
      "if player.x-8 > e.x then e.vx +=spd end"
      "if player.x+8 < e.x then e.vx -=spd end"
      "if player.y-8 > e.y then e.vy +=spd end"
      "if player.y+8 < e.y then e.vy -=spd end"
      ""
      "apply_accel(e,1)"
      "move(e)"
      "end"
      ""
      "function draw_puffer(e)"
      "local sinfo=e.spr_info[e.state]"
      "local sprites = sinfo.sprites"
      "local flipx,sprw,sprh,xoff,yoff = ternary(player.x>e.x,true,false),1,1,-4,-4"
      ""
      "if e.state==\"puffed\" then xoff,yoff,sprw,sprh,flipx = -8,-8,2,2,not flipx  end"
      "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
      "drawoutline(spri,e.x+xoff,e.y+yoff,sprw,sprh,flipx,false,0,true)"
      "end"
      ""
      "function create_squid(x,y,shark)"
      "local e=new_object(x,y,\"squid\",update_squid,draw_squid)"
      "e.up=false"
      "e.invinci=false"
      "local sa,sb= 76,77"
      "if shark then"
      "e.name,e.up,sa,sb=\"shark\",true,74,90"
      "end"
      ""
      "e.spr_info={"
      "idle = {"
      "sprites = {sa},"
      "dt=0.02"
      "},"
      "swim = {"
      "sprites = {sa,sb},"
      "dt=6"
      "}"
      "}"
      "e.abs_box=function()"
      "local xa,ya=3,7"
      "if e.name==\"shark\" then xa,ya=7,3 end"
      "return new_box(e.x-xa,e.y-ya,e.x+xa,e.y+ya)"
      "end"
      "add(objects, e)"
      "return e"
      "end"
      ""
      "function create_shark(x,y)"
      "create_squid(x,y,true)"
      "end"
      ""
      "function update_squid(e)"
      "e.animt+=1"
      "if e.name==\"squid\" then"
      "e.up=ternary(e.vy<0,true,false)"
      "e.invinci=ternary(((player.y>e.y-3 and not e.up) or (player.y<e.y+3 and e.up)),true,false)"
      ""
      "else"
      "e.up=ternary(e.vx<=0,true,false)"
      "end"
      ""
      "if e.state=='idle' then"
      "apply_friction(e,wtrfrc)"
      "if e.animt>30 then change_state(e,'swim') end"
      "else"
      "if e.animt>120 then change_state(e,'idle') end"
      "if e.name==\"squid\" then"
      "e.vy+=ternary(e.up,-0.1,0.1)"
      "else"
      "e.vx+=ternary(e.up,-0.1,0.1)"
      "end"
      "apply_accel(e,1.5)"
      "end"
      "move(e)"
      "end"
      ""
      "function draw_squid(e)"
      "local sinfo = e.spr_info[e.state]"
      "local sprites = sinfo.sprites"
      "local spri = sprites[flr(e.animt/sinfo.dt)%#sprites+1]"
      "local flipy,flipx,xa,ya,sx,sy = false,false,3,7,1,2"
      "if e.name==\"squid\" then"
      "flipy=ternary(e.up,false,true)"
      "else"
      "flipx=ternary(e.up,true,false)"
      "xa,ya,sx,sy=7,3,2,1"
      "end"
      "drawoutline(spri,e.x-xa,e.y-ya,sx,sy,flipx,flipy,0,true)"
      "end"
      ""
      "function create_spikey(x,y,mine)"
      "local e=new_object(x,y,\"spikey\",update_spikey,draw_spikey)"
      "e.spri=22"
      "e.bob=true"
      "e.flash=0"
      "e.invinci=true"
      ""
      "e.seed = flr(rnd(30))"
      "e.abs_box=function()"
      "return new_box(e.x-3,e.y-3,e.x+3,e.y+3)"
      "end"
      "if mine then e.name = \"mine\" e.spri=10 end"
      "add(objects, e)"
      "return e"
      "end"
      ""
      "function create_mine(x,y)"
      "return create_spikey(x,y,true)"
      "end"
      ""
      "function create_field(x,y,cols,rows,xspace,yspace,mine)"
      "local ypos = y"
      "for i=1,cols do"
      "for i=1,rows do"
      "create_spikey(x,ypos,mine)"
      "ypos+=yspace"
      "end"
      "x+=xspace"
      "ypos=y"
      "end"
      "end"
      ""
      "function create_trap(x,y)"
      "local m = create_mine(x,y)"
      "m.state=\"detonate\""
      "create_field(x-10,y-10,2,2,20,20)"
      "create_bubbles(x,y,14,15,2,4)"
      "end"
      ""
      "function update_spikey(e)"
      "e.vy+=ternary(e.bob,0.01,-0.01)"
      ""
      "if (t+e.seed)%30==0 then e.bob = not e.bob end"
      ""
      "if e.state==\"detonate\" then"
      "e.animt+=1"
      "if e.animt>=60 then"
      "create_explosion(e.x,e.y,15)"
      "create_bubbles(e.x,e.y,10,15,2,4)"
      "add_shake(8)"
      "sfx(14)"
      "local pdist = dist(player.x,player.y,e.x,e.y)"
      "if pdist<=30 and player.state != \"hurt\" and player.invinci==0 then"
      "hurt_player(player)"
      "bounce_relative(player,e,9-pdist/4)"
      "end"
      "for o in all(objects) do"
      "local odist = dist(o.x,o.y,e.x,e.y)"
      "if odist<=30 then"
      "if o.name == \"mine\" or o.name == \"spikey\" then"
      "bounce_relative(o,e,9-odist/4)"
      "if o.name ==\"mine\" then change_state(o,\"detonate\") end"
      "else"
      "kill_object(o)"
      "end"
      "end"
      "end"
      ""
      "del(objects,e)"
      "elseif e.animt>=40 and e.animt%2==0 then"
      "e.flash =0.1"
      "elseif e.animt>=0 and e.animt%10==0 then"
      "e.flash =0.2"
      "end"
      "end"
      "apply_friction(e,wtrfrc)"
      "move(e)"
      "end"
      ""
      "function draw_spikey(e)"
      "drawoutline(e.spri,e.x-4,e.y-4,1,1)"
      "flashobject(e,7)"
      "spr(e.spri,e.x-4,e.y-4,1,1)"
      "pal()"
      "end"
      ""
      ""
      "function create_clam(x,y)"
      "local e =new_object(x,y,\"clam\",update_clam,draw_clam)"
      "e.flipx=false"
      "e.wob=true"
      "e.invinci=true"
      "e.shakesound=false"
      ""
      "e.abs_box=function()"
      ""
      "local box = new_box(e.x-7,e.y-3,e.x+7,e.y+3)"
      "if e.state==\"open\" then box.y1-=4 box.y2+=4 end"
      "return box"
      "end"
      "add(objects,e)"
      "return e"
      "end"
      ""
      "function update_clam(e)"
      "e.animt+=1"
      "if is_offscreen(e,60) then return end"
      "if e.state==\"idle\" then"
      "e.flipx=ternary(player.x>e.x,true,false)"
      "if e.animt >=60 then"
      "if not e.shakesound and not is_offscreen(e) then sfx(15) e.shakesound=true end"
      "if t%2==0 then"
      "if e.wob then"
      "e.x+=2"
      "else"
      "e.x-=2"
      "end"
      "e.wob=not e.wob"
      "end"
      "end"
      "if e.animt >=80 then"
      "change_state(e,\"open\")"
      "e.shakesound=false"
      "e.invinci=false"
      "end"
      "end"
      ""
      "if e.state==\"open\" then"
      "if e.animt==1 then"
      "local vx = (player.x-e.x)/dist(player.x,player.y,e.x,e.y)"
      "local vy = (player.y-e.y)/dist(player.x,player.y,e.x,e.y)"
      "create_bubbles(e.x,e.y-3,rnd(3)+2,4,1,3)"
      "create_pearl(e.x,e.y-2,vx*2,vy*1.6)"
      "sfx(16)"
      "end"
      "if e.animt>=120 then"
      "change_state(e,\"idle\")"
      "e.invinci=true"
      "end"
      "end"
      "end"
      ""
      "function draw_clam(e)"
      "local spri,yoff,h=29,-7,1"
      ""
      "if e.state==\"open\" then"
      "spri,yoff,h=8,-15,2"
      "end"
      "drawoutline(spri,e.x-8,e.y+yoff,2,h,e.flipx,false,0,true)"
      "end"
      ""
      "function create_pearl(x,y,vx,vy)"
      "local e=new_object(x,y,\"pearl\",update_pearl,draw_pearl)"
      "e.vx=vx"
      "e.vy=vy"
      ""
      "e.abs_box=function()"
      "return new_box(e.x-2,e.y-2,e.x+2,e.y+2)"
      "end"
      ""
      "add(objects,e)"
      "return e"
      "end"
      ""
      "function update_pearl(e)"
      "if e.x<-20 or e.x>roomcols*140 or e.y<-20 or e.y>roomrows*140 then"
      "del(objects,e)"
      "end"
      "move(e)"
      "end"
      ""
      "function draw_pearl(e)"
      "drawoutline(26,e.x-2,e.y-2,1,1,false,false,0,true)"
      "end"
      ""
      "function create_exit(x,y)"
      "local e={"
      "x=x,"
      "y=y,"
      "name='exit',"
      "state='open',"
      "combat=false,"
      "abs_box=new_box(x-4,y-4,x+4,y+4)"
      "}"
      "exit = e"
      "return e"
      "end"
      ""
      "function update_exit()"
      "if exit.combat==true and exit.state==\"closed\" then"
      "local no = 0"
      "for i in all(objects) do"
      "if i.name==\"mine\" or i.name==\"spikey\" or i.name==\"pearl\" then"
      "no+=1"
      "end"
      "end"
      "if #objects-no <= 0 then"
      "exit.state=\"open\""
      "music(5)"
      "create_bubbles(exit.x,exit.y,10,6,2,4)"
      "end"
      "end"
      "if t%60==0 then create_bubbles(exit.x,exit.y,rnd(1)+1,2,1,2) end"
      "end"
      ""
      "function coll_exit()"
      "if coll(exit.abs_box,player.abs_box()) then"
      "if exit.state==\"open\" and player.state!=\"dead\" then"
      "sfx(29)"
      "next_room()"
      "end"
      "end"
      "end"
      ""
      "function draw_exit()"
      "local ca,cb=0,0"
      "if exit.state==\"closed\" then ca,cb= 13,2 end"
      "pal(8,0)"
      "pal(9,ca)"
      "pal(10,cb)"
      "spr(108,exit.x-8,exit.y-8,2,2)"
      "pal()"
      "end"
      ""
      "function create_ink(x1,y1,x2,y2,uprate,both)"
      "e = {"
      "box=new_box(x1,y1,x2,y2),"
      "uprate=uprate or 0,"
      "both=both or false,"
      "name=\"ink\","
      "update=update_ink,"
      "coll=coll_ink,"
      "draw=draw_ink"
      "}"
      "e.uprate*=0.1"
      "add(hazards,e)"
      "return e"
      "end"
      ""
      "function update_ink(e)"
      "local box=e.box"
      "box.y1-=e.uprate"
      "if e.both then box.y2-=e.uprate end"
      "if box.y2<0 then del(hazards,e) end"
      ""
      "local cbox =new_box(camx-20,camy-20,camx+148,camy+148)"
      ""
      "if coll(box,cbox) then"
      "if t%3==0 then"
      "local x1,y1,x2,y2=box.x1,box.y1,box.x2,box.y2"
      "local tblen,rllen,off = x2-x1,y2-y1,10"
      "for i=1, flr((tblen+64)/64) do"
      "create_particle(flr(rnd(tblen)+x1),y1+off,0,(rnd(0.2)+0.2+e.uprate)*-1)"
      "create_particle(flr(rnd(tblen)+x1),y2-off,0,rnd(0.2)+0.2-(e.uprate*0.9))"
      "end"
      "for i=1, flr((rllen+64)/64) do"
      "create_particle(x2-off,flr(rnd(rllen)+y1),rnd(0.2)+0.2,0)"
      "create_particle(x1+off,flr(rnd(rllen)+y1),(rnd(0.2)+0.2)*-1,0)"
      "end"
      "end"
      "end"
      "end"
      ""
      "function coll_ink(e)"
      "local box = e.box"
      "local ps = player.state"
      "if coll(box,player.abs_box()) and ps!=\"attack\" and ps!=\"hurt\" and ps!=\"dead\" then"
      "local centre = {}"
      "centre.x = box.x1+box.x2/2"
      "centre.y = box.y1+box.y2/2"
      "hurt_player(player)"
      "bounce_relative(player,centre,2)"
      "end"
      "end"
      ""
      "function draw_ink(e)"
      "local b = e.box"
      "palt(0,false)"
      "rectfill(b.x1,b.y1,b.x2,b.y2,0)"
      "pal()"
      "end"
      ""
      ""
      "function update_boss()"
      "boss.animt+=1"
      "if boss.wave>0 then boss.wave-=1 player.vy-=0.4 add_shake(1)end"
      "if boss.state==\"active\" then"
      "if coll(player.abs_box(),boss.box) then"
      "if player.state==\"attack\" then"
      "cancel_attack()"
      "sfx(21)"
      "boss.hp-=1"
      "add_shake(4)"
      "if boss.hp<=0 then"
      "sfx(22)"
      "change_state(boss,\"dying\")"
      "for i in all(objects) do"
      "kill_object(i)"
      "end"
      "end"
      "end"
      "bounce_relative(player,boss,2)"
      "end"
      "if t%150==0 then"
      "create_bubbles(arg\"64,640,20,40,2,3,\")"
      "create_ink(arg\"-20,640,146,660,13,true,\")"
      "boss.wave=40"
      "music(3)"
      "end"
      "elseif boss.state==\"dying\" then"
      "if t%2==0 then"
      "create_explosion(rnd(80)+20,rnd(128)+512,rnd(8)+8)"
      "end"
      "if t%flr(rnd(10)+4)==0 then sfx(14) add_shake(4) end"
      "if boss.animt>=150 and player.state!=\"dead\"then change_state(boss,\"dead\") next_room() end"
      "end"
      "end"
      ""
      "function draw_boss()"
      "drawoutline(arg\"69,48,576,4,4,false,false,0,true,\")"
      "if boss.hp<3 then"
      "spr(arg\"73,69,596,\")"
      "if boss.hp<2 then"
      "spr(arg\"73,52,596,1,1,false,true,\")"
      "spr(arg\"73,66,580,1,1,true,\")"
      "if boss.hp<1 then"
      "spr(arg\"73,56,581,1,1,true,true,\")"
      "spr(arg\"73,62,588,1,1,\")"
      "end"
      "end"
      "end"
      "end"
      ""
      "-->8"
      "--object utils"
      ""
      "function spawnlist(l)"
      "local ol = parse(l)"
      "for i=1,#ol,3 do"
      "local t,x,y=ol[i],ol[i+1],ol[i+2]"
      "spawntype(t,x,y)"
      "end"
      "end"
      ""
      "function spawntype(type,x,y)"
      "if type==3 then"
      "create_snapper(x,y)"
      "elseif type==4 then"
      "create_puffer(x,y)"
      "elseif type==5 then"
      "create_squid(x,y)"
      "elseif type==1 then"
      "create_spikey(x,y)"
      "elseif type==2 then"
      "create_mine(x,y)"
      "elseif type==0 then"
      "create_exit(x,y)"
      "elseif type==6 then"
      "create_clam(x,y)"
      "elseif type==7 then"
      "create_school(x,y)"
      "elseif type==8 then"
      "create_shark(x,y)"
      "end"
      "end"
      ""
      "function coll(a,b)"
      "return not (a.x1>b.x2 or a.y1>b.y2 or a.x2<b.x1 or a.y2<b.y1)"
      "end"
      ""
      "function move(o)"
      "o.x+=o.vx"
      "o.y+=o.vy"
      "end"
      ""
      "function kill_object(e)"
      "add_shake(5)"
      "create_explosion(e.x,e.y,5)"
      "create_bubbles(e.x,e.y,rnd(2)+2,4,1,3)"
      "for i=1,flr(rnd(4)+3) do"
      "create_particle(e.x,e.y,rnd(3)+-2,rnd(3)+-2,true)"
      "end"
      "sfx(7)"
      "del(objects,e)"
      "freeze=2"
      "end"
      ""
      ""
      "function apply_friction(o,fric)"
      "o.vx*=fric"
      "o.vy*=fric"
      "end"
      ""
      "function bounce(o,bx,by)"
      "if bx then o.vx = bx end"
      "if by then o.vy = by end"
      "end"
      ""
      "function bounce_relative(p,o,str)"
      "local rdist = dist(p.x,p.y,o.x,o.y)"
      "local bouncex = (p.x-o.x)/rdist"
      "local bouncey = (p.y-o.y)/rdist"
      "bouncex*=str"
      "bouncey*=str"
      "bounce(p,bouncex,bouncey)"
      "end"
      ""
      "function change_state(o,state)"
      "if o.state != state then"
      "o.state = state"
      "o.animt = 0"
      "end"
      "end"
      ""
      "function apply_accel(o,tpspd)"
      "local l=dist(o.vx,o.vy)"
      "local rl=min(l,tpspd)"
      "o.vx=o.vx/l*rl"
      "o.vy=o.vy/l*rl"
      "end"
      ""
      "function issolid(x, y)"
      "local tile,col,row = gettile(x,y)"
      "if tile then"
      "ox = (x-(col*128))/8"
      "oy = (y-(row*128))/8"
      "offsetx = (tile%8)*16"
      "offsety = flr(tile/8)*16"
      "val=mget(ox+offsetx, oy+offsety)"
      "return fget(val, 1)"
      "end"
      "end"
      ""
      "function detectwalls(o)"
      "local hb = o.abs_box()"
      "local x1,x2,y1,y2,xc,yc=hb.x1,hb.x2,hb.y1,hb.y2,0,0"
      "local adjust = 0.1"
      ""
      "for i=y1,y2 do"
      "if x1-1<0 or issolid(x1-1,i) then"
      "o.x+=adjust"
      "xc+=1"
      "end"
      "if x2+1>cmaxx or issolid(x2+1,i) then"
      "o.x-=adjust"
      "xc+=1"
      "end"
      "end"
      ""
      "for i=x1,x2 do"
      "if y1-1<0 or issolid(i,y1-1) then"
      "o.y+=adjust"
      "yc+=1"
      "end"
      "if y2+1>cmaxy or issolid(i,y2+1) then"
      "o.y-=adjust"
      "yc+=1"
      "end"
      "end"
      ""
      "if xc>0 and xc>=yc then bounce(o,o.vx*-0.8,nil) end"
      "if yc>0 and yc>=xc then bounce(o,nil,o.vy*-0.8) end"
      ""
      "if (xc>0 or yc>0) and o.name==\"player\" and o.state==\"attack\" then"
      "if (player.dir==2 or player.dir==6) and yc>xc then"
      "else"
      "cancel_attack()"
      "end"
      "end"
      "end"
      ""
      "function setdirection(o,bl,br,bu,bd)"
      "if bu and not(bl or br or bd) then o.dir = 0 end"
      "if br and not(bu or bl or bd) then o.dir = 2 end"
      "if bd and not(bl or bu or br) then o.dir = 4 end"
      "if bl and not(bd or br or bu) then o.dir = 6 end"
      "if (bu and br) and not(bl or bd) then o.dir = 1 end"
      "if (br and bd) and not(bl or bu) then o.dir = 3 end"
      "if (bd and bl) and not(br or bu) then o.dir = 5 end"
      "if (bl and bu) and not(br or bd) then o.dir = 7 end"
      "end"
      ""
      "function add_shake(p)"
      "local a=rnd(1)"
      "shkx+=p*cos(a)"
      "shky+=p*sin(a)"
      "end"
      ""
      "function is_offscreen(o,buffer)"
      "local buf = buffer or 0"
      ""
      "if o.x<camx-buf or o.x>camx+127+buf or o.y<camy-buf or o.y>camy+127+buf then return true end"
      "end"
      ""
      "-->8"
      "--effects--"
      ""
      ""
      "function create_explosion(x,y,r)"
      "local e={"
      "x=x,"
      "y=y,"
      "r=r,"
      "p=0,"
      "draw=draw_explosion,"
      "}"
      "add(fx,e)"
      "end"
      ""
      "function draw_explosion(s)"
      "if s.p<2 then"
      "circfill(s.x,s.y,s.r,0)"
      "elseif s.p<4 then"
      "circfill(s.x,s.y,s.r,7)"
      ""
      "if s.p<3 and s.r>4 then"
      "for i=0,2 do"
      "local x=s.x+rnd(2.2*s.r)-1.1*s.r"
      "local y=s.y+rnd(2.2*s.r)-1.1*s.r"
      "local r=0.25*s.r+rnd(0.5*s.r)"
      "create_explosion(x,y,r)"
      "end"
      "end"
      "elseif s.p<5 then"
      "circ(s.x,s.y,s.r,7)"
      ""
      "del(fx,s)"
      "return"
      "end"
      ""
      "s.p+=1"
      "end"
      ""
      "function create_bubbles(x,y,num,spread,minsize,maxsize)"
      "for i=1,num do"
      "local a=rnd(1)"
      "local b={"
      "x=x+spread*cos(a),"
      "y=y+spread*sin(a),"
      "r=rnd(maxsize-minsize)+minsize,"
      "draw=draw_bubble"
      "}"
      "add(fx,b)"
      "end"
      "end"
      ""
      "function draw_bubble(b)"
      "circ(b.x+0.5,b.y+0.5,b.r,13)"
      "circfill(b.x+0.5-b.r*0.4,b.y+0.5-b.r*0.4,b.r*0.2,6)"
      "b.y-=b.r*0.6"
      "if(b.y<0)then del(fx,b) end"
      "end"
      ""
      "function create_fern(x,y,len,col)"
      "f={x=x,y=y,len=len,col=col,flipx=false,draw=draw_fern}"
      "f.bub=flr(rnd(1080)+720)"
      "add(fx,f)"
      "end"
      ""
      "function draw_fern(f)"
      "if t%50==0 then f.flipx=not f.flipx end"
      "if flr(t+1080)%f.bub==0 then create_bubbles(f.x+3,f.y,1,1,1,2) end"
      "pal(8,f.col)"
      "for i=1,f.len do"
      "if i==f.len then"
      "spr(105,f.x,f.y-i*8,1,1,f.flipx)"
      "else"
      "spr(121,f.x,f.y-i*8,1,1,f.flipx)"
      "end"
      "end"
      "pal()"
      "end"
      ""
      ""
      "function flashobject(o,c)"
      "if o.flash > 0 then"
      "o.flash-=0.1"
      "for i=0,15 do"
      "pal(i,c)"
      "end"
      "else"
      "o.flash = 0"
      "end"
      "end"
      ""
      "function drawoutline(n,x,y,w,h,flip_x,flip_y,c,main)"
      "for i=1,15 do"
      "pal(i,c)"
      "end"
      ""
      "for xx=-1,1 do"
      "for yy=-1,1 do"
      "spr(n,x+xx,y+yy,w,h,flip_x,flip_y)"
      "end"
      "end"
      "pal()"
      "if main then spr(n,x,y,w,h,flip_x,flip_y) end"
      "end"
      ""
      "function boldprint(str,x,y,col)"
      "c=col or 7"
      "for xx=-1,1 do"
      "for yy=-1,1 do"
      "print(str,x+xx,y+yy,0)"
      "end"
      "end"
      "print(str,x,y,c)"
      "end"
      ""
      "function create_particle(x,y,vx,vy,pp)"
      "p = {"
      "x=x,"
      "y=y,"
      "vx=vx,"
      "vy=vy,"
      "cols={0,0,2},"
      "size=10,"
      "age=0,"
      "maxage=30"
      "}"
      "if pp then"
      "p.size=1"
      "p.maxage=15"
      "p.cols={7,7,7,6,6,12}"
      "p.pp=true"
      "end"
      "add(particles,p)"
      "end"
      ""
      "function update_particles()"
      "for p in all(particles) do"
      "p.age+=1"
      "if p.age==p.maxage or is_offscreen(p,30) then del(particles,p) end"
      "local ci = 1+flr((p.age/p.maxage)*#p.cols)"
      "p.col = p.cols[ci]"
      "if p.age/p.maxage > 0.6 then p.fill = fades[4] end"
      "if p.age/p.maxage > 0.8 then"
      "p.fill = fades[2]"
      "if not p.pp then"
      "p.size=14"
      "end"
      "end"
      ""
      "move(p)"
      "end"
      "end"
      ""
      "function draw_particles()"
      "for p in all(particles) do"
      "if p.fill then fillp(p.fill) end"
      "circfill(p.x,p.y,p.size,p.col)"
      "fillp()"
      "end"
      "end"
      ""
      "-->8"
      "--utilities--"
      ""
      "function parse(string)"
      "local data = {}"
      "local d = \"\""
      "for i=1,#string do"
      "local s = sub(string,i,i)"
      "if s != \",\" then"
      "d=d..s"
      "else"
      "if d==\"true\" then"
      "d=true"
      "elseif d==\"false\" then"
      "d=false"
      "else"
      "d=flr(d)"
      "end"
      "add(data,d)"
      "d=\"\""
      "end"
      "end"
      "return data"
      "end"
      ""
      "function arg(str)"
      "return unpack(parse(str))"
      "end"
      ""
      "function unpack(t,i)"
      "i=i or 1"
      "if t[i]!=nil then"
      "return t[i],unpack(t,i+1)"
      "end"
      "end"
      ""
      "function ternary(c,a,b)"
      "if c then return a else return b end"
      "end"
      ""
      "function gettile(x,y)"
      "local col = flr(x/128)"
      "local row = flr(y/128)"
      "local tile = roomtiles[(roomcols*row)+row+col+1]"
      "return tile,col, row"
      "end"
      ""
      "function dist(xa,ya,xb,yb)"
      "if xb then xa=xb-xa ya=yb-ya end"
      "local d = max(abs(xa),abs(ya))"
      "local n = min(abs(xa),abs(ya)) / d"
      "return sqrt(n*n +1)*d"
      "end"
      ""
      "function new_box(x1,y1,x2,y2)"
      "return {x1=x1,y1=y1,x2=x2,y2=y2}"
      "end"
      ""
      "function timer()"
      "local min,sec=gm,flr(gt/30)"
      "if min<10 then"
      "min=\"0\"..min"
      "end"
      "if sec<10 then"
      "sec=\"0\"..sec"
      "end"
      "return min..\":\"..sec"
      "end"
      "")
    (p8-section gfx
      "000000000088e0000088e000000008e8000008e8000e0000000e0000000c0000000000000001d000002222000000000000000000000000677777000000060000"
      "0000000000178e0000178e000008718800087188e008e0000008e000000c000000000000001dd50002e2222000000000000076700d6666666666770000676000"
      "00700700007788e0007788e00e8877820e8877828882871ee882871e000c000000000000001dd5002e26d222000000000777776000dddddd6666676007777700"
      "0007700002888880028888800082888200888882288887788888877800cc600000000000001d5dd0226e8d220000000076667770000000000006777607676700"
      "000770002888822028282820ee8888200088282088888882288888820c71600000000000001dd5d022d88521000000776666670000dddddd6666676076666670"
      "007007000088220000882200882882000888822000228820802882200c77c60000000000001ddddd222d5211000007666d0667000d6666666666770076606670"
      "000000000088800000888000082820000288200000022200000222000cccc600000000000001dd5d0222211000000666d0d66700000000677777000076606670"
      "00000000088280000088280000800000002800000000000000000000dccccc60000000000001ddd5001111000000666d0d667000000000000000000076606670"
      "00000006600000000060000660000000000000066000000060000006d0cccc00000000000001dd5d0f77000000066dd0d6670000000000000000000076d0d670"
      "66000000cc66000000c60000cc66000000000000cc660000060e206000ccc000000000ffee001dddf77760000006d00d666700000000000dd555000066d0d660"
      "0c6066ccc77cc0000c6c666cc77cc000000066ccc77cc0000062260000dcc0000002efeeeee211d57777600000dd000d6670000000d5dd555ddd5d0006d0d600"
      "0cccccccc71cccccccccccccc71ccccc666cccccc71ccccc0e22222000ddc000d12222eeee2221d07776d00000d000d660000000d11d5dddddddd1d006d0d600"
      "0cc0dddcccccc0000000dddcccccc0000cc0dddcccccc00002222110000c0000ddd11111111111d0066d000000000d6600000000ddd1111111111dd006d0d600"
      "dd00000ddcc000000000000ddcc00000ddd0000ddcc0000000d21d0000cc600000dddddddddddd00000000000000dd000000000000dddddddddddd0006d0d600"
      "00000000d000000000000000d00000000d000000d00000000d0110d00cddd60000000d5d5d5d500000000000000000000000000000000d5d5d5d50000d000d00"
      "000000000000000000000000000000000000000000000000d000000d0d000c000000000000000000000000000000000000000000000000000000000000000000"
      "000000000000000000000000000000000000000000000000000c0000000c00000006000000000000000000000000000000000000000000000000000000000000"
      "00000000000000c000000000000000c000000000000000c0000c0000000c000000006000000000000060006000000000000000000000000000000000000000c0"
      "0000000000000c000000000000000c000000000000000c00000c0000000c0000000cc0000000000000cc0c600000000006660000000000000000000006000c00"
      "000000000000c000000000000000c000000000000000c00000cc600000cc6000c0ccc00060000000000dcc006000000000ccc00060000000000000066cccc000"
      "00000006cccc000000000006cccc000000000006cccc00000c7160000c7160000dddc660060000000000cc6006000000000cc660060000000000006c17cc0000"
      "0000006cc71c00000000006cc71c00000000006cc71c00000c77c6000c77c6000000dccccc0000000000dccccc00000000cddccccc00000006006ccc77cc0000"
      "00006cccc77c000000006cccc77c000000006cccc77c00000cccc6000cccc60000000ccccc60000000000ccccc6000000dd00ccccc6000000c60ccccccc00000"
      "00060ccccccd000000060ccccccd000000060ccccccd0000dccccc60dccccc6000000dcdccc6000000000dcdccc6000000000dcdccc600000dc6cccccd000000"
      "00000ccdccd0000000000ccdccd0000000000ccdccd00000d0cccc00d0cccc00000000dccccc0000000000dccccc0000000000dccccc000000dcddddd0000000"
      "0000cccccd0000000000cccccd0000000660cccccd00000000ccc00000ccc000000000dcc77c0000000000dcc77c0000000000dcc77c000000dcccd000000000"
      "00006ddd0000000000006ddd0000000000c6cddd0000000000dcc00000dcc0000000000dc71c00000000000dc71c00000000000dc71c000000cccc0000000600"
      "066ccd00000000000006cd0000000000000ccd000000000000ddc00000ddc00000000000dccc000000000000dccc000000000000dccc0000000dccc66000cc00"
      "60ccc00000000000006cc0000000000000ccd00000000000000c0000000c0000000000000000c000000000000000c000000000000000c0000000dcccc66cc000"
      "000cd0000000000000ddd000000000000dd000000000000000cc0000000cc0000000000000000c000000000000000c000000000000000c0000000ddccccc0000"
      "0000d000000000000d000d00000000000000000000000000ccdd0000000dcc6000000000000000c000000000000000c000000000000000c00000000ddddc0000"
      "000d00000000000000000000000000000000000000000000000c0000000dd00000000000000000000000000000000000000000000000000000000000000d0000"
      "ffffffff0333333333333333333333303333333300000000000066666666000000000000000070009900009900000000000f4000000f40000000000400000000"
      "fff8fff83353533553533535535353333355333300000000066600000000666000000000000070000990000990000000000f400000044000000400f4ff040000"
      "fff88f8e35e5e35ee5e53e5e35e5255335ee53550000000660000000000000066000000000000700009999999997700000044000000f400000004fff4f4f0000"
      "fff888ef5efff5effefe5fef5ef2e2235effe5ee0000006d0000777700000000060000000000700000999999999719990049940000f944000004ffff4ffff000"
      "8888888fefffffffffffefffeffeeee5effffeff000006d000777777000000000d60000000770000009ff9999999999900f9940000f94400044fffffffffff00"
      "ee888888fffffffffffffffffffeeee2ffffffff00006dd0777700000000000000d600007700700009900ffff99fff9000f9940000f4940000fff77fffff7100"
      "fffe8eeefffffffffffffffffffeeeeeffffffff00065dd7777000000000000000dd600000000700990000fff99fff0000f94400004994000ffff17fffff77f0"
      "ffff8ffffffffffffffffffffffeeeeeffffffff0065057770000000000000000dd556000000000000000000990000000f94994004f994400f44fffffffffff0"
      "fff33fffeeeeeeeeddd55555eee22222ff4444ff00600777d000000000000000dd5006001a1a1a1a09000099000000000f4999400f99944004ffffffffffff44"
      "fff31fffeeeeeeeed1111112eee22222f49ff94f06007775dd0000000000000dd5000060a1a1a1a10090000990000000049999400f994940044ffff4ffff4ff0"
      "ff3333ffffffffffddd55552fffeeeee4fe44fe4060077005dd00000000000dd500000601a1a1a1a009999999997700044499444f4449944004fff4ffffff400"
      "f3b3331feeeeeeee51111112eee222224949f4940600770005dddd0022000dd500000060a1a1a1a10099999999971999f7794774f779977400444ffff4ffff40"
      "f333311feeeeeeee5dd55552eee222224f4f4fe46007700000dd2222222ddd50000000061a1a1a1a009ff99999999999f7144174f7144174000444ffff4ff000"
      "e333311feeeeeeee51111112eee222224949e94e60077000005225222222dd0000000006a1a1a1a100900fff99ffff900488884004888840000044444ff40000"
      "fe3111eeeeeeeeee5dd55552eee222224fe444ef600770000022222222222500000000061a1a1a1a090000ff99ffff0000808800080808000000004444000000"
      "ffeeeeeeffffffff52222222fffeeeeef44eeeff60077000022222222222220000000006a1a1a1a1000000099000000008080080080080800000000000000000"
      "fffffffffffffffffffffffffffeeeeeffffffff60000000022222222222210000000006000000001111111a11111111000000dddd00000000004f0000004f00"
      "fffffffffffffffffffffffffffeeeeeffffffff6000000002228822228821000002000600088000111111a1a11111110000dd5555550000000fff40000fff40"
      "fff9fffffffffffffffffffffffeeeeeffffffff600000000022288228821100002000560088880011111a1a1a111111000d555225555000f0f17f1700f17f17"
      "fffffffffffffffffffffffffffeeeeeffffffff60000000021222222221120022100056008488001111a1a1a1a1111100d55229a22555004ff77f77fff77f77"
      "ffffffffeffffffffffffffffffeeee2ffffff9f0600002221001222211112222000006000848800111a1a1a1a1a11110d552a89a8925550ffffffff4fffffff"
      "ffffffff2efffffffffffffffffeee22f9ffffff06000210000006ddd5100010000005600848800011a1a1a1a1a1a1110d529a89a89a25500044fff4f04ffff4"
      "ffffffff02eeeeeeeeeeeeeeeeeee220ffffffff06000200000006ddd500000000005560084880001a1a1a1a1a1a1a11d5529a89a89a2552000fff40000f4f40"
      "ffffffff002222222222222222222200ffffffff006020000000008e280000000000560000848800a1a1a1a1a1a1a1a1d5289a89a89a8d520000440000004400"
      "5d555522fffffffffffeeeeefffffffffffeeeee006000000000080e2800000000055600008488001a1a1a1a1a1a1a1ad5289a89a89a8d52555555555d555522"
      "5d555522eeeeeeeeeee22222fffffffffffeeeee0006000000000e8200800000005560000008488011a1a1a1a1a1a1a1d5589a89a89a8522dddddddd5d555522"
      "5d555522eeeeeeeeeee22222fffffffffffeeeee0000600000000028e80000000556000000084880111a1a1a1a1a1a11055d9a89a89ad520555555555d555522"
      "5d555522fffffffffffeeeeefffffffffffeeeee000006000000008028e0000055600000008488001111a1a1a1a1a1110255da89a89d5220555555555d51d522"
      "5d555522fffffffffffeeeeefffffffffffeeeee000000600000e802e00e0055560000000084880011111a1a1a1a111100255dd9add52200555555555d5d5522"
      "5d555522eeeeeeeeeee22222fffffffffffeeeee00000006600e082e000555566000000008488000111111a1a1a111110002555dd5522000555555555d555522"
      "5d555522fffffffffffeeeeefffffffffffeeeee0000000006660082e805666000000000084880001111111a1a1111110000255555220000222222225d555522"
      "5d555522fffffffffffeeeeefffffffffffeeeee000000000000666666660000000000000084880011111111a11111110000002222000000222222225d555522"
      "16262626262626262626262637373737373737373737373737373737373737373737373737373737373737373737374737373737373737373737373737373737"
      "3737373737373737373737373737373737374637373746063737373737043737070000a7b7000000000000a7b700000707000700000000000000000000070007"
      "a7959595951646373737373737373737373737373737373737373737373737373737373737373737373737373746374706370646063737063737370637373737"
      "37373737370637373737373737373737262626262626463737374637373737370700000000000000000000000000000707a607a6a6a6a6a6a6a6a6a6a607a607"
      "00a79595959537063737063737063737373737063737063737373737374637373746373737373737373737373737064737374604463706463737262626262626"
      "262626262626262646373737063737373695959595b6162626263706373746370700000000000000000000000000000707b707b7b7b7b7b7b7b7b7b7b707b707"
      "000000b7a79546373746370637373737373737373737373737463737370637373737373737374637373737460637374737370646370637373706263695959595"
      "95959595951626262606373737373737959595959595b6162626262626373737070000a6b6000000000000a6b60000070700f700000000000000000000070007"
      "00000000009517171717171717171717171717171717171717171717171717171717171717171717171717171717172717171717171717171727959595959595"
      "9595959595959595951717171717171795959595959595b600000017171717170795959595959595959595959595950707000700000000000000000000070007"
      "0000000000a715151515151515151515151515151515151515151515151515151515151515151515151515151515153515151515151515151535959595959595"
      "959595959595959595151515151515159595a795959595950000a61515151515f70000a7b7000000000000a7b700000707e7e725b6b6b6b6b6b6b6b625e7e707"
      "00000000000017171717171717171717171717171717171717171717171717171717171717171717171717171717172717171717171717171727959595959595"
      "9595959595959595951717171717171795b6959595959595b6959517171717170700000000000000000000000000000707a7a707a7a7a7a7a7a7a7a707a7a707"
      "0000000000a646063737064637373704373737373737064637373737373737373737463737374637064637374637063637370626262626262636959595959595"
      "95959595959595959516262606370637959595959595959595959516262606370700000000000000000000000000000707000007000000000000000007000007"
      "00000000a69515151515151515151515151515151515151515151515151515151515151515151515151515151515350015151535959595959595959595959595"
      "95959595959595959595959515151515959595959595959595959595951515150700000000000000000000000000000707000007000000000000000007000007"
      "0000a695959506370637373737373737373737373737370637373737373737373737372626262626262626262626360037463747959595959595959595959595"
      "959595959595959595959595163746379595959595959595959595959537370607000000000000a6b6000000000000f707a6b607b6a6b6a6b6a6b6a6f7a6b607"
      "00009595951424373746373737373737373737373737370637373706373746373737373746373737460637373747b7003737374795959595b70000a695959595"
      "95959595b795a795b7a79595953737379595959595959595959595951424373725e7e725959595959595959525e7e72507b7a707a7b7a7b7a7b7a7b707b7a707"
      "00a695b7951717171717171717171717171717171717171717171717171717171717171717171717171717171727000017171727959595950000a69595959595"
      "9595b700a695b600a6b6a7b7001717179595959595959595959595951717171707000000000000a7b700000000000007f7e7e7e72500000000000025e7e7e707"
      "009595a695063737373737373737373737373737063737373737373737373737373737373737373737063737464700003737373695959595b695959595959595"
      "95b7a695959595959595b6a6953737379595b7a79595959595959595374637370700000000000000000000000000000707000000070000000000000700000007"
      "00959595144424373737374637373737373737370637373737370637373737374637373737063737373737370447000046374795959595959595959595951424"
      "44349595959595959595959595464637442434b6a795959514242424064506370700000000000000000000000000000707a6a6a607a6a6a6b6b6b607b6b6b607"
      "a6951424243737373737373737373706370637373737373737373737373737373737373737373737370637373747b60006464795959595959595959595143737"
      "0637349595959595959595959506373746372424442424440646370637460637070000a6b6000000000000a6b600000707a7a7a707a7a7a7b7b7b707b7b7b707"
      "142406463737373737373737463737373746370646373737063746463746370637373737373737373737373737244434373747959595b7959595959595374606"
      "4637479595959595959595959537373737373737374637373706373737373737f795959595959595959595959595950707000000070000000000000700000007"
      "37373737373737373737373737373737373737373737373737373737063737370000000000000000000000000000000037374795959595959595959595063737"
      "4506479595959595959595959537373700000000000000000000000000000000072500a7b7000000000000a7b7002507e7e7e7e7e725b6b6a6a625e7e7e7e7e7"
      "06370637373706373737063737463737373737373737373737374637373737370000000000000000000000000000000037374795959595959595959595163706"
      "46373695959595959595959595370637000000000000000000000000000000000707000000000000000000000000070707070707e7079595959507e707070707"
      "373737373737463737373706370637263737373737373737373737373737373700000000000000000000000000000000370647959595959595959595b7001626"
      "2636959595959595959595959537373700000000000000000000000000000000070700000000000000000000000007070707f707e7259595959525e707f70707"
      "46063737262626262626262626263695373737063747373737473737370637370000000000000000000000000000000046062434959595959595959500000095"
      "959595959595959595959514243746060000000000000000000000000000000007070000000000a6b60000000000070707070725959595959595959525070707"
      "171717171727b7a695959595959595951717171717271717172717171717171700000000000000000000000000000000171717279595959595a695b70000a695"
      "95959595959595959595951717171717000000000000000000000000000000000707959595959595959595959595070707072595959595b7a79595959525f707"
      "15151515353695959595959595959595151515151535151515351515151515150000002525250000000000252525000015151535959595959595b70000959595"
      "959595b700a69595959595151515151500000000000000000000000000000000f7070000000000a7b700000000000707f70795b79595950000959595a7950707"
      "17171717279595959595959595959595171717171727172717271717171717170000002525250000000000252525000017171727959595b700000000a6959595"
      "9595b70000959595b795951717171717000000000000000000000000000000000707000000000000000000000000070707079595b7959500009595a795950707"
      "37373737369595959595959595959595373737063747374737473737373737370000002525250000000000252525000037463724349595000000a69595959595"
      "959500a69595959500000037370637370000000000142444244444243400000007e72500000025e7e72500000025e7070725959595b795000095a79595952507"
      "1515153595959595959595b7959595951515151515351535153515151515151500000007070700000000000707070000151515153595b7000095959595959595"
      "95959595959595b7000000151515151500000000000637374637370647000000070007a6b600079595f700a6b6070007079595959595b70000a79595959595f7"
      "373737242434959595959595959595953706262606473747374726263737373700000007070700000000000707070000373706462424444434a7959595959595"
      "9595959595b7000000000037064637370000000000171717171717172700000007950795959525e7e7259595950795070795b700000000000000000000a79507"
      "37374637242444442444349595959595064795b746470647374795b7370637370000000707072444340000070707340037374606373737372424243495959595"
      "95959514443400001444443737373737000000000016262626262626360000000700f7a7b7000000000000a7b70700070795b600000000000000000000a69507"
      "17171717171717171717279595959595172795001727172717279500171717170000140707070646242444070707063417171717171717171717172795959595"
      "9595951717271434171717171717171700000000000000a7959595950000000007000700000000000000000000f70007079595959595b60000a6959595959507"
      "373737373737373737373724442434953747950006471636464795003737063714444607f7074637063706070707460637373737373706373737373724443495"
      "9595953706470647370646370437373700000000000000000000a7b70000000007000700000000000000000000070007f725959595b695070795a69595952507"
      "373737373737064637373737373737243747b700163600000647b700162637373725e725e725e7254625e725e725e72537373737374637460637373737064624"
      "444424243747373737373737373737370000000000000000000000000000000007000700000000a6b600000000f7000707079595b6959507079595a695950707"
      "3737063737370646063706373737370637470000000000001636000000003746460746064637370706f706374637460737373737373706370637373737063737"
      "06373737373737373737373737373737000000000000000000000000000000000795079595959595959595959507950707f725b69595252525259595a625f707"
      "373737373737373737373737373737372636000000000000000000000000162625e7e7e7e7e7e7e7e7e7e7e7e7e7e7e737373737373737373737373737373737"
      "373737373737373737373737373737370000000000000000000000000000000007000700000000a7b700000000070007070707e7e7e7e7e7e7e7e7e7e7070707")
    (p8-section label
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffff9fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fffffffffffffffff9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff4444ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fffffffffffffffffffffffffffffffffffffffffffffffffffffffff49ff94fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fff9fffffffffffffffffffffff9fffffffffffffff9ffffffffffff4fe44fe4fffffffffff9ffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff4949f494ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff4f4f4fe4ffffffffffffffffffffff9fffffffffffffffffffffffffffffff9fffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff4949e94efffffffffffffffff9fffffffffffffffffffffffffffffff9ffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff4fe444efffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fffffffffffffffffffffffffffffffffffffffffffffffffffffffff44eeeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9fffffffffffffffffffffffff"
      "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9ffffffffffffffffffffffffffffff"
      "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeffffffffffffffffffffffffffffffffffffffffeeeeeeee"
      "22222222222222222222222222222222222222222222222222222222222222222222222222222222ffffffffffffffffffffffffffffffffffffffff22222222"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010fffffffffffffffffffffffffffffffffffeeeee10101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101fffffffffffffffffffffffffffffffffffeeeee01010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010fffffffffffffffffffffffffffffffffffeeeee10101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101fffffffffffffffffffffffffffffffffffeeeee01010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010effffffffffffffffffffffffffffffffffeeee210101010"
      "010101010101010101010101010101010101010101010101010101010101010101010101010101012efffffffffffffffffffffffffffffffffeee2201010101"
      "1010101010101010101010101010101010101010101010101010101010101010101010101010101012eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee22110101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101112222222222222222222222222222222222221101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101011101010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010111110101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101111111010101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101011111111101010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010111111111110101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101111111111111010101010"
      "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101011111111111111101010101"
      "10101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101111111010101010"
      "01088101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101011111110108810101"
      "10888810101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101111101088881010"
      "01884801010101010101010101000001010000010100000101000001010000010100000101000001010000010100000101010101010101011111010188480101"
      "10884810101010101010101010007700100707001000770010077700100770001007770010077700100077001007070010101010101010101110101088481010"
      "01088481010101010101010101070001010707010107070101070701010707010107000101007001010700010107070101010101010101011101010108848101"
      "10188480101010101010101010077700100707001007070010077000100707001007701010107010100777001007770010101010101010101010101018848010"
      "01884801010101010101010101000701010777010107070101070701010707010107000101007001010007010107070101010101010101010101010188480101"
      "10884810101010101010101010077000100777001007700010070700100777001007001010077700100770001007070010101010101010101010101088481010"
      "08848101019901010101010101000001010000010100000101000001010000010100010101000001010000010100000101010101010101010199010884810101"
      "18848010199990101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101999901884801010"
      "01884801099491010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010994910188480101"
      "10884810199490101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101994901088481010"
      "01088481019949010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010199490108848101"
      "10188480109949101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101099491018848010"
      "01884801099491010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010994910188480101"
      "10884810199490101010101010101010101010101010101010101010101010101010101011111111111111111111111110101010101010101994901088481010"
      "08848101994901010aa1010101010101010101010101010101010101010101010101010111111111111111111111111101010101010aa1019949010884810101"
      "1884801099491010aaaa10101010101010101010101010101010101010101010101010111111111111111111111111111010101010aaaa109949101884801010"
      "0188480109949101aa4a01010101010101010101010101010101010101010101010101111111111111111111111111110101010101aa4a010994910188480101"
      "1088481019949010aa4a10101010101010101010101010101010101010101010101011111111111111111111111111111010101010aa4a101994901088481010"
      "01088481019949010aa4a10101010101010101010101010101010101010101010101111111111111111111111111111101010101010aa4a10199490108848101"
      "10188480109949101aa4a01010101010101010101010101010101010101010101011111111111111111111111111111110101010101aa4a01099491018848010"
      "0188480109949101aa4a01010101010101010101010101010101010101010101011111111111111111111111111111110101010101aa4a010994910188480101"
      "1088481019949010aa4a10101010101010101010101010101010101010101010111111111111111111111111111111101010101010aa4a101994901088481010"
      "088481019949010aa4a10101ff01010101010101010101010101010101010101111111111111111111111111111111010101ff010aa4a1019949010884810101"
      "188480109949101aa4a0101ffff010101010101010101010101010101010101011111111111111111111111111111010101ffff01aa4a0109949101884801010"
      "0188480109949101aa4a010ff4f101010101010101010101010101010101010111111111111111111111111111110101010ff4f101aa4a010994910188480101"
      "1088481019949010aa4a101ff4f010101010101010101010101010101010101011111111111111111111111111101010101ff4f010aa4a101994901088481010"
      "01088481019949010aa4a101ff4f010101010101010101010101010101010101111111111111111111111111110101010101ff4f010aa4a10199490108848101"
      "10188480109949101aa4a010ff4f101010101010101010101010101010101010111111111111111111111111101010101010ff4f101aa4a01099491018848010"
      "0188480109949101aa4a010ff4f101010101010101010101010101010101010111111111111111111111111101010101010ff4f101aa4a010994910188480101"
      "1088481019949010aa4a101ff4f010101010101010101010101010101010101011111111111111111111111110101010101ff4f010aa4a101994901088481010"
      "088481019949010aa4a101ff4f010107710101010101010101010101010101011111111111111111111111110101077101ff4f010aa4a1019949010884810101"
      "188480109949101aa4a010ff4f101077771010101010101010101010101010111111111111111111111111111010777710ff4f101aa4a0109949101884801010"
      "0188480109949101aa4a010ff4f101774701010101010101010101010101011111111111111111111111111101017747010ff4f101aa4a010994910188480101"
      "1088481019949010aa4a101ff4f010774710101010101010101010101010111111111111111111111111111110107747101ff4f010aa4a101994901088481010"
      "01088481019949010aa4a101ff4f010774710101010101010101010101011111111111111111111111111111010107747101ff4f010aa4a10199490108848101"
      "10188480109949101aa4a010ff4f101774701010101010101010101010111111111111111111111111111111101017747010ff4f101aa4a01099491018848010"
      "0188480109949101aa4a010ff4f101774701010101010101010101010111111111111111111111111111111101017747010ff4f101aa4a010994910188480101"
      "1088481019949010aa4a101ff4f010774710101013333333333333333333333333333333333333311111111010107747101ff4f010aa4a101994901088481010"
      "088481019949010aa4a101ff4f010774710101013353533553533535535335355353353553535333111111010107747101ff4f010aa4a1019949010884810101"
      "188480109949101aa4a010ff4f1017747010101035e5e35ee5e53e5ee5e53e5ee5e53e5e35e52553111110101017747010ff4f101aa4a0109949101884801010"
      "0188480109949101aa4a010ff4f10177470101015efff5effefe5feffefe5feffefe5fef5ef2e2231111010101017747010ff4f101aa4a010994910188480101"
      "1088481019949010aa4a101ff4f0107747101010efffffffffffefffffffefffffffefffeffeeee51110101010107747101ff4f010aa4a101994901088481010"
      "01088481019949010aa4a101ff4f010774710101fffffffffffffffffffffffffffffffffffeeee211010101010107747101ff4f010aa4a10199490108848101"
      "10188480109949101aa4a010ff4f101774701010fffffffffffffffffffffffffffffffffffeeeee10101010101017747010ff4f101aa4a01099491018848010"
      "0188480109949101aa4a010ff4f1017747010101fffffffffffffffffffffffffffffffffffeeeee0101010101017747010ff4f101aa4a010994910188480101"
      "3333333333333333333333333333333333333333ffffffffffffffffffffffff3333333333333333333333333333333333333333333333333333333333333333"
      "3355333353533535535335353355333333553333ffffffffffffffffffffffff5353353553533535535335353355333333553333535335355353353533553333"
      "35ee5355e5e53e5ee5e53e5e35ee535535ee5355ffffffffffffffffffffffffe5e53e5ee5e53e5ee5e53e5e35ee535535ee5355e5e53e5ee5e53e5e35ee5355"
      "5effe5eefefe5feffefe5fef5effe5ee5effe5eefffffffffffffffffffffffffefe5feffefe5feffefe5fef5effe5ee5effe5eefefe5feffefe5fef5effe5ee"
      "effffeffffffefffffffefffeffffeffeffffeffffffff9fffffffffffffffffffffefffffffefffffffefffeffffeffeffffeffffffefffffffefffeffffeff"
      "fffffffffffffffffffffffffffffffffffffffff9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fffffffffffffffffff9fffffffffffffffffffffffffffffffffffffff9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9ffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffff9fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9fffffffff"
      "fffffffffffffffffffffffffffffffff9fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9ffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      "")
    (p8-section gff
      "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003030303030000000000000000000000030303030300000000010000000000000303030303000000000001010000000003030303030000000000010100000303"
      "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (p8-section map
      "0000000000000000000000000000000073606262626262626262626262627360000000000000000000000000000000006162626273647373737373737373737373736473737373737373737373737373737373737373737374717171726073737373736073737373737364607373737373736473736073736064737373626263"
      "00000000000000000000000000000000646300007a597b007a597b7a59596173000000000000000000000000000000007a597b0073607362627364737373737360737360736073547360647373736473737373736473737374736073747360736262626262626262626262626262627373737373647373626262626263595959"
      "0000000000000000000000000000000074596b0000596b000059000059597b730000000000000000000000000000000000596b006162635959616262626262626262626262626262626273736473736262626262626262626351515153616262635959595959595959595959595959616262626262626262635959595959597b"
      "000000000000000000000000000000007459596b005959006a596b0059590064000000000000000000000000000000000059596b5900597b7a59595959595959595959595959595959596162626263595959596b6b6a5959597171717259595959595959595959595959595959595959595959595959595959596a59597b0000"
      "00000000000000000000000000000000727a595900595900597a590059596b7100000041424300000000000000000000007a59597b0059000059596b6a5959595959595959595959595959595959595959595959595959595971717172595959595959595959595959595959595959596b7a597b7a595959595959597b000000"
      "0000000000000000000000000000000053007a596b597b00590059007a5959510000006162636b00000000000000000000007a590000596b6a5959595959595959595959595959595959595959595959595959595959595959616262635959595959594144424444424244437a5959595959590000007a59597b7a596b000000"
      "000000000000000000000000000000007200005959596a59596b590000007a71000000007a595900000000000000000000006a59006a59595959595959595959595959595959595959595959597b7a59595959595959595959595959595959595959597373736064737373740059595959597b006a6b00595900005959000000"
      "00000000000000000000000000000000746b007a595959595959590000006a7300000000007a59596b0000414443000000005959005959597b6b597b0000595959595959595959595959595959596a5959595959595959595959595959595959595959717171717171717172006a595959596b6a59595959596b005959000000"
      "0000000000000000000000000000000072596b005959595959597b00006a5951000000000000595959006a7171720000006a597b00597a595959590000005959595959595959595959595959595959595959595959595959595959595959595959597b6054607373736473746a595959595959597a5959595959595959000000"
      "00000000000000000000000000000000747a596b59597a5959596b006a597b7300000000000059595959596162630000007a596b007a595959597b00006a595959595959595959597b00000059595959595959597b595959594142444359595959596b51515151515151515359595959597b7a595959007a7b00006a596b0000"
      "0000000000000000000000000000000074007a59597b007a7b7a59007a5900600000000000007a59595959597b000000000059590000597a595900000059595959595959595959590000006a5959595959597b00007a595959736073745959595959596162626262626262635959595959006a5959596b000000007a59590000"
      "000000000000000000000000000000007200007a5900006a6b005900005900710000000000006a5959597b0000000000006a7b7a6b0059005959006a59595959595959595959597b00000059595959595959004143005959595151515359595959595959595959595959595959595959595959595959595959596b6a59596b00"
      "0000000000000000000000000000000074000000590000597b0059000059007300000000414443597b00000000000000005900005900596b4142444243595959595959595941424242436a5959595959597b006074007a595971717172595959595959595959595959595959595959594142424242435959414244444243596b"
      "000000000000000000000000000000007400000059006a590000590000596b73000000006162637b00000000000000006a596b6a596b4142444242444444424244424244446473734242424444424244444242424242424242424242424242424359595959595959595959595959594142424244444242424242424244624359"
      "000000000000000000000000000000007443006a596b597b006a596b6a594173000000000000000000000000000000004142424444427340736473737373607373736073737373607373737373737373737373737373737373737373737373734242424244424244424244444442446073737364737350736064444444424243"
      "0000000000000000000000000000000060744142444442444442444242447373000000000000000000000000000000007373736073736073736073737373647373737373647373737373737373606473737373737373737373737373737373737373737373647373736073737373737373737360737373737373737373736074"
      "00000000000041444242444242444244414244430000000000004142444442424442444244424244444242430000000073737459595959595959595959737373736474595959595959595959597373737364745959595959595959595964737300000000000000000000007474747373424359596b000000000000006a595941"
      "0000000041444273736473736073606073734244424444430000736073646473737373737360647373736474000000007373424359595959597b59595973737373607459595959595959595959647360737374595959595959595959597360730000000000000000000000637474607373745959595959595959595959595964"
      "000000414242737373737364546073737373607364734244444442736040607373737373736050647373424243000000736460745959595959006a5959736473737342435959595959595959596050647360745959590000007a59595973647300000000000000000000007a637473737342435959597b000000007a59594160"
      "0041426473737373737373606473737373737373737373737360737373606073737373737373737373607360424243007373606359595959590059595961736073736042437a59595959595959736073626263595959004144424244444273730000000000000000000000005972717273734243590000006a59595959416060"
      "00717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171720071717259597b0059595959595959717171717171726b6a595959595959717171717259595959007171717171717171710000000000000000000000005963737471717172596b006a5959595959717171"
      "0051515151515151515151515151515151515151515151515151515151515151515151515151515151515151515153005151535959597b6a5959595959595151515151515359595959595959595151515153595959596b5151515151515151510000000000000000000000007a59647451515153595959597a59595959515151"
      "007171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717200717172595959595959595959595971717171717172595959597b595959717171717259595959597171717171717171710000000000000000000000000059616371717172595959000059595959717171"
      "00616262626262626273737360607373737373737360737373647373737373736073737373737373646062626262630064644243595959007a7b7a595941737373607373745959597b007a5959616273607459595959596174746262626273730000000000000000000000006a59596b737342424359596b00007a5941736073"
      "007a51515151515151515151515151515151515151515151515151515151515151515151515151515151515153597b0051515153597b596b000000595951515151515151535959590000000059595951515359595959595963635959595151510000000000000000000000007a5959595151515153595959596b005951515151"
      "000073737373737373737373737360737373737373736073737364646073737373737373737373737373737374596b0073737374596a59596b006a595960736073736062635959590000000059595960734243595959595959595959596173730000000000000000000000006a59597b73737364745959595959595960607373"
      "00007373737364737373737373737373737373737373737373737373737373737373737373737373736064737459590073646263597a5959595959597b6173546073737459595959596b006a5959417373407459595959595959595959597373000000000000000000000000595959007373647363597b005959595961737360"
      "006a717171717171717171717171717171717171717171717171717171717171717171717171717171717171727a5900717172595900000000000000005971717171717259597b00007a595959597171717172595959595959595959595971710000000000000000000000007a59596b7171717259596b595959595959717171"
      "0041737373737373737364737373737373737373737373737373737373737373737373737373737373737342444359007360745959596b00000000006a59616473737374595900000000597a59417373737342424444444243595959594142730000000000000000000000007a6a59597373737459597b7a7a59595959737373"
      "41424242424242737373737373407373737373737373737373737373737373737373737373737373737373737374596b736463596a59595959595959597b59737360606359596b000000596b00736073737362626262746263595959597373734243000000000000000000005959414473607363595900006a59595959736073"
      "7360737364737364737373737373737373737373647373737373647373737373737373736473737373737373734244434074595959597b00007a59595959597373647459595959596b00595959606473737374595974635959595959597373735153000041436b004144436a595960406064745959596a595959595959647364"
      "7373737360737373737373737373737373737373737373737373737373736073737373737373737373737373737364746263597b0000000000000000007a5961737374595959595959595959597373737373745959635959595959595973737373746b6a60745959647374595941737373737459595959595959595959736073")
    (p8-section sfx
      "0114000005611086210c6210c6210c6210c6210b6310b6310c6310e6410f6411264115641186511b6611b6511c6611a671186711567113671106610e6510b6510964108631076210662105611036110261101611"
      "010400000a0510c0510f0511105100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010400000e05110051120511305100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "000400001305115051170511905120553285030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "01040000225531e5531a55316553135530f5530d55303500015001b0001800016000120000f0000d0000800006000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010600000a0500a050010500105000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010400002945312053314532055327053366570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010400002245122451264512645121654226512065521100000002110021100000000000021100211000000021100211000000000000000000000000000000000000000000000000000000000000000000000000"
      "011000000161101611016110361105611046110161101611026110461105611046110361102621016310162101621016210161101611016110161102611036210662105621046210362103621046110161101611"
      "010100000505305053050530405304053040530205302053020530005300053000530000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "01100000114301143011440114401145011460114601146011470114701147011470114701146011460114500c4600c4600c4700c4700c4700c4700c4600c4500c4500c4500c4500c4400c4400c4400c4300c430"
      "01100000212222122221222212322123221242212422125221252212522125221252212422124221232212321c2621c2521c2521c2521c2421c2421c2321c2221c2221c2221c2221c2121c2121c2121c2021c202"
      "011000001814118151181511815124151241512414124131181611815118151181511815118151181511814113161131511315113151131511315113141131411313113131131311312113121131211311113111"
      "01100000281122811228122281222813228132281422814228152281522816228162281612815228152281522815228152281522815228142281322812228112281122811228112281121c1121c1121c1121c112"
      "01040000291531c1530e1530015000050000500005000050001030010300103001030010300103001030010300103001030010300103001030010300103001030000000000000000000000000000000000000000"
      "010800001103504535110350453511035045351103504535110350453511035045350c00500005000050000500005000050000500005000050000500005000050000500005000050000500000000000000000000"
      "0104000013530297531c5101a51010510105100050000501005010050100501005010050100501005010050100501005010050100501005010050100501005010050100501005010050100501005010050000500"
      "011000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010300000c7230c7230c7230c7230c7230c7330c7430c7530c7630c7630c7530c7430c7330c7230c7230c7330c7330c7430c7530c7630c7630c7530c7430c7330c7230c7330c7330c7430c7430c7330c7230c723"
      "000300001173311743117531176311763117531175311743117431173311743117431175311753117531175311753117631176311763117531174311743117331173311733117431174311743117531176311753"
      "0103000002023030230402307023080330b0330b03308023070130802309023080230603306043080530a0630b0630c0630b05309043070330603305033040230402305033070430703306023060230601306003"
      "010500003664327345336513634533651336512462124611246111861118615000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "0105000032355346513b355376513465135345356413b641346413b631393353b631396313762132325326213b621346113631518611186111861118611186111861118611186111861118611186111861118611"
      "010500000c521105311f5412355124533245000050100501005010050100501005010050100501005010050100501005010050100501005010050100501005010050100501005010050100501005010000000000"
      "0105000024531235311f5411c55118543000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010a00001144011450114601146011460114601146011450114401144011430114301142011410114101141000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010a00001c2221c2221c2221c2221c2321c2321c2421c2521d2721d2621d2521d2421d2321d2221d2121d21200000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010a00001814118151181511815121151211512114121131111511115111141111311112111111111111111100000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010a00002811228112281222812228132281422814228152291522915229142291322912229112291122911200000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "010600001d0341d0711d0711d015000001d0141d0151800000000180001d0141d0151d0001800018000180001d0001d0001800000000000000000000000000000000000000000000000000000000000000000000"
      "001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      "011000000c0533f415000003c6150c0533f3153c615000000c0533f415000003c6150c0533f4153c615000000c0533f3153f3153c6150c0533f4153c615000000c053000003f3153c6150c0533f4153c61500000"
      "011000000c0533f200000003c6150c0533f2003c615000000c0533f200000003c6150c0533f2003c615000000c0533f2003f2003c6150c0533f2003c615000000c053000003f2003c6150c0533f2003c61500000"
      "011000000c05329454264453c6150c0532f3453c6152b3520c05328352294523c6150c0533f2003c615000000c0533f200293503c6150c053283503c615293500c05329440263553c6150c053000003c61500000"
      "011000000014000020001100010000140000200011000100001400002000110001000014000020001100010000140000200011000100001400002000110001000014000020001100010000140000200011000100"
      "011000000414004020041100410004140040200411004100041400402004110041000414004020041100410004140040200411004100041400402004110041000414004020041100410004140040200411004100"
      "011000000714007020071100710007140070200711007100071400702007110071000714007020071100710007140070200711007100071400702007110071000714007020071100710007140070200711007100"
      "011000000514005020051100510005140050200511005100051400502005110051000514005020051100510005140050200511005100051400502005110051000514005020051100510005140050200511005100"
      "011000000914009020091100910009140090200911009100091400902009110091000914009020091100910009140090200911009100091400902009110091000914009020091100910009140090200911009100"
      "011000000214002020021100210002140020200211002100021400202002110021000214002020021100210002140020200211002100021400202002110021000214002020021100210002140020200211002100")
    (p8-section music
      "00 00424344"
      "02 08424344"
      "04 0a0b0c0d"
      "00 12134344"
      "04 13144344"
      "04 191a1b1c"
      "00 41424344"
      "00 41424344"
      "01 22234344"
      "00 22244344"
      "00 22254344"
      "00 22254344"
      "00 22264344"
      "00 22274344"
      "00 22254344"
      "02 22284344"
      ""))
  (lossless-raw-segments
    (hex 0 "7069636f2d3820636172747269646765202f2f20687474703a2f2f7777772e7069636f2d382e636f6d0a76657273696f6e2034320a5f5f6c75615f5f0a2d2d73776f7264666973682076312e300a2d2d62792064616e206c616d62746f6e2d686f776172640a2d2d20323031380a0a2d2d726f6f6d20646174610a0a66756e6374696f6e206c6f61645f726f6f6d5f6461746128290a726f6f6d73203d207b0a7b0a7265663d222d32302c2d32302c222c0a74696c65733d2231342c342c2d312c222c0a737061776e3d22302c3330302c3135302c222c0a6665726e733d22302c3130342c332c382c382c3130342c322c392c33322c3131322c322c382c3430")
    (hex 256 "2c3131322c312c322c34392c3132382c322c382c35362c3132382c332c31342c39312c3132382c322c382c3130342c3132302c342c322c3131322c3130342c342c382c3132312c3130342c362c31342c3132382c3130342c362c382c3133352c3130342c352c392c3134322c3130342c342c31302c3134392c3130342c332c31352c3135362c3130342c322c372c3231382c3130342c322c372c3232352c3130342c332c31352c3233322c3130342c342c31302c3233392c3130342c352c392c3234362c3130342c362c382c222c0a74726967676572733d7b7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a6966207469746c")
    (hex 512 "6573207468656e0a706c617965722e6f66663d747275650a706c617965722e6469723d320a696620743d3d323030207468656e0a7469746c65733d66616c73650a6e6578745f726f6f6d28290a656c7365696620743d3d3830207468656e206d757369632832290a656c7365696620743e3d3330207468656e0a6368616e67655f737461746528706c617965722c227377696d22290a706c617965722e76782b3d302e330a656e640a656c73650a696620743d3d3130207468656e0a6d757369632830290a706c617965722e6f66663d747275650a706c617965722e6469723d330a706c617965722e76783d340a706c617965722e76793d350a656e640a6966")
    (hex 768 "20743d3d3430207468656e20706c617965722e6469723d3220706c617965722e76783d3120656e640a696620743d3d3630207468656e20706c617965722e6f66663d66616c736520656e640a656e640a656e640a7d2c7b0a7061727365223230302c36342c33302c302c302c222c0a66756e6374696f6e28290a7469746c65733d747275650a743d300a656e640a7d7d0a7d2c0a0a7b0a7265663d2233322c3139322c222c0a74696c65733d2231382c322c32392c31362c31372c31392c32302c2d312c372c302c322c332c342c32382c31322c2d312c31382c32392c382c31372c31372c31372c31312c2d312c222c0a6665726e733d2233322c3232342c32")
    (hex 1024 "2c392c34302c3232342c332c392c3138322c3331322c352c392c3139302c3331322c352c382c3230322c3331322c342c392c3232302c3331322c332c392c3135352c3338342c372c392c3136302c3338342c382c382c3139302c3338342c352c392c3234302c3338342c382c392c3331322c35362c322c382c3332342c35362c332c392c3333362c35362c342c382c3334362c35362c322c382c3437302c3232342c382c382c3438302c3232342c382c392c3530312c3233322c392c382c3531372c3233322c31302c392c3533312c3233322c362c392c3534342c3233322c382c31302c3535382c3232342c382c392c3537352c3232342c382c31302c353933")
    (hex 1280 "2c3233322c392c372c3630352c3233322c352c31302c3632302c3233322c372c372c3633382c3233322c362c372c222c0a737061776e3d22302c3834322c3334322c382c3137322c37302c382c3231362c3233322c382c3339362c36382c220a7d2c0a0a7b0a7265663d2236342c33322c222c0a74696c65733d2231352c31372c2d312c31322c31372c2d312c31322c31372c2d312c32372c32302c2d312c31372c31312c2d312c31372c31352c2d312c31372c31312c2d312c222c0a6665726e733d2232342c3237322c332c372c33322c3238302c332c31312c34302c3435362c322c372c38302c3436342c342c372c39362c3438302c342c372c3130382c")
    (hex 1536 "3438302c322c31312c3132302c3438382c352c372c3132372c3438382c332c332c3133342c3438382c342c31312c3134342c3439362c342c332c3135322c3532302c362c31312c222e2e223134342c3635362c332c332c3135322c3636342c332c332c3136302c3639362c352c332c3232342c3639362c362c332c3233322c3636342c342c31312c3234302c3635362c352c332c222c0a737061776e3d22302c3139322c3833322c382c37322c3137322c382c38322c3330302c382c36342c3337382c382c3134382c3633322c382c3233342c3634362c220a7d2c0a0a7b0a74696c65733d22332c342c352c32312c2d312c222c0a6665726e733d223131302c")
    (hex 1792 "3130342c322c332c3133342c3130342c322c332c3134392c3130342c342c332c3233302c3130342c332c332c3233372c3130342c332c332c3236392c3130342c322c332c3337342c3130342c322c332c3339382c3130342c322c332c3431332c3131322c352c332c3432322c3131322c342c332c3434362c3130342c322c332c3436312c3130342c342c332c222c0a737061776e3d22302c3434382c36342c312c3134302c34302c312c3232302c36352c312c3232302c38302c312c3232302c39352c312c3334342c36302c312c3331302c39352c220a7d2c0a0a7b0a74696c65733d22342c372c302c302c332c2d312c222c0a6665726e733d223130302c31")
    (hex 2048 "30342c322c332c3133342c39362c322c332c3134392c39362c332c332c3233302c39362c322c332c3233392c3130342c332c332c3531362c3131322c322c332c3533342c3131322c332c332c3534392c3131322c362c332c3632322c3130342c342c332c222c0a737061776e3d22302c3537362c36342c332c3137362c36342c332c3335322c362c332c3335322c3132302c312c3330302c36342c312c3433362c33322c312c3433362c39362c332c3530302c35302c332c3530302c37382c220a7d2c0a0a7b0a7265663d2236342c37342c747275652c222c0a74696c65733d22312c2d312c222c0a6665726e733d22382c3131322c322c332c33322c313230")
    (hex 2304 "2c322c332c3130342c3132302c332c332c3131322c3131322c332c332c222c0a737061776e3d22302c36342c36342c332c32302c3130382c332c3130382c3130382c332c3130382c32302c332c32302c32302c220a7d2c0a0a0a7b0a7265663d223139322c3139322c222c0a74696c65733d2231392c342c32302c2d312c32372c32312c31322c2d312c332c342c32382c2d312c222c0a6665726e733d223139392c3233322c332c392c3230362c3233322c332c392c39392c3232342c322c31352c3130362c3232342c332c31352c33322c3138342c322c392c3231352c3130342c332c392c3233302c3130342c332c31352c3233372c3130342c322c392c33")
    (hex 2560 "36302c3232342c332c31352c3336382c3230382c322c31352c37302c3335322c322c392c38302c3335322c342c392c39302c3335322c352c31352c3130302c3335322c372c392c3131302c3336302c31302c392c3132302c3336302c382c392c3133302c3336302c392c31352c3134302c3336302c372c392c3135302c3336302c31302c392c3136302c3336302c31302c392c3137302c3335322c382c392c3138302c3335322c352c392c3139302c3335322c392c392c3230302c3335322c372c392c3231302c3336302c362c392c3232302c3336302c372c392c3233302c3336302c382c392c3234302c3336302c362c31352c3235302c3336302c342c392c")
    (hex 2816 "3236302c3336302c372c392c3237302c3336302c382c392c3238302c3333362c372c392c3239302c3333362c382c392c3330302c3333362c362c31352c3331302c3334342c352c392c3332302c3333362c382c392c3333302c3333362c362c31352c222c0a737061776e3d22302c33322c3332302c342c39352c3136302c342c3231302c33322c342c3335302c3231302c332c3239302c3239352c332c3331302c3239352c382c38302c3332302c382c36342c3239362c382c36342c3334342c222c0a7d2c0a0a7b0a7265663d2236342c37342c747275652c222c0a74696c65733d22312c2d312c222c0a737061776e3d22302c36342c36342c342c36342c32")
    (hex 3072 "302c342c32382c3130302c342c3130302c3130302c222c0a6665726e733d22382c3131322c352c392c33322c3132302c362c392c3130342c3132302c342c392c3131322c3131322c332c392c31362c3132302c352c392c35312c3132302c332c392c37372c3132302c332c31352c38342c3132302c352c392c222c0a7d2c0a0a7b0a7265663d2236342c3139322c222c0a74696c65733d2231382c302c332c342c32302c2d312c372c302c31362c31372c31322c2d312c31372c392c31372c32342c32382c2d312c222c0a6665726e733d223136342c3236362c352c31342c3139362c3237322c362c31322c3232302c3235362c352c31342c3236302c323438")
    (hex 3328 "2c372c31322c3132302c3132302c332c31322c3530322c3130342c342c31322c3530392c3130342c332c31342c3630342c3238302c342c31342c3438302c3335322c362c31342c3438382c3335322c352c31322c3530322c3336302c352c31322c222c0a737061776e3d22302c3435342c3331342c352c3137302c36342c352c3230302c3132382c352c3233302c3139362c352c3336382c38302c352c3339322c32302c352c3431362c38302c352c3536322c3137382c352c3537362c36302c352c3539302c3232382c352c3438362c3332302c220a7d2c0a0a7b0a7265663d2236342c37342c747275652c222c0a74696c65733d22312c2d312c222c0a6665")
    (hex 3584 "726e733d2232342c3132302c322c31322c33342c3132302c312c31342c37342c3132302c342c31322c39342c3132302c332c31342c3130342c3132302c322c31342c222c0a737061776e3d22302c36342c36342c352c33322c39362c352c39362c33322c382c33322c33322c382c39362c39362c222c0a7d2c0a0a7b0a7265663d2232362c36342c222c0a74696c65733d22332c342c342c352c342c362c32312c2d312c222c0a6665726e733d223130342c3130342c332c31332c3131312c3130342c322c352c3132352c3130342c322c31332c3133322c3130342c342c352c3133392c3130342c332c352c3135322c3130342c322c31332c3232362c313034")
    (hex 3840 "2c332c352c3235382c3130342c322c31332c3335342c3130342c342c352c3338362c3130342c322c352c3432362c3130342c332c31332c3433332c3130342c322c352c3434302c3130342c332c31332c3530302c3130342c322c31332c3532302c3130342c332c31332c3637302c34302c332c352c3638302c34302c332c31332c3639302c34302c322c31332c3730302c34302c312c352c3731302c34302c322c31332c3732302c34302c332c31332c3733302c34302c322c352c3637302c3131322c312c31332c3638302c3131322c322c31332c3639302c3131322c322c352c3730302c3131322c332c31332c3731302c3131322c322c31332c3732302c31")
    (hex 4096 "31322c322c352c3733302c3131322c322c31332c222c0a737061776e3d22302c3832302c36342c362c3234362c3130322c362c3433382c3130322c312c3437322c36302c362c3531322c3130322c352c3635362c34382c352c3734382c34382c362c3639322c3131322c362c3639322c34302c220a7d2c0a0a7b0a7265663d223132382c3137362c747275652c222c0a74696c65733d2231392c32302c2d312c32372c32382c2d312c222c0a6665726e733d2234302c3230302c342c31332c37322c3230382c322c352c39362c3232342c332c31332c3130342c3232342c322c352c3132302c3233322c342c31332c3132382c3233322c352c352c3133362c32")
    (hex 4352 "33322c332c31332c3134342c3233322c342c31332c3135362c3230382c322c31332c3136362c3230382c332c352c3138302c3231362c332c352c3139322c3230382c332c352c3232342c3135322c352c31332c222c0a737061776e3d22302c3132382c34382c362c35362c3230302c362c3138342c3231362c362c3132382c3130342c312c3132302c38382c312c3133362c38382c220a7d2c0a0a7b0a74696c65733d2232342c342c32312c2d312c222c0a737061776e3d22302c3332302c36342c372c3235362c35362c372c3235362c37322c222c0a6665726e733d223139322c39362c322c382c3330342c3131322c322c392c3332302c3130342c322c38")
    (hex 4608 "2c220a7d2c0a0a7b0a7265663d2238322c36342c222c0a74696c65733d2232342c342c372c302c2d312c31372c31372c31382c302c2d312c31372c31372c31382c302c2d312c31372c31372c31372c31352c2d312c222c0a737061776e3d22302c3435302c3530302c352c3134302c33302c342c3234302c36342c352c3333382c36342c362c3337362c3234362c362c3339302c3338322c352c3430302c36302c352c3433322c3132302c352c3436342c3236302c352c3439362c3136302c222c0a6669656c64733d223139342c34322c332c312c38302c302c747275652c3233342c38382c332c312c38302c302c747275652c3430382c31322c312c332c30")
    (hex 4864 "2c3133352c747275652c3437382c36362c312c342c302c38322c747275652c3434382c3130322c312c352c302c36302c747275652c3432362c3431322c332c322c32352c32302c747275652c222c0a74726967676572733d7b7b0a7b7d2c0a66756e6374696f6e28290a6c6f63616c206d3d6372656174655f6d696e65283133302c3734290a6d2e73746174653d226465746f6e617465220a656e640a7d7d0a7d2c0a0a7b0a74696c65733d22372c322c302c332c32302c31372c2d312c32352c392c392c31372c31312c31372c2d312c302c332c32302c31382c302c31362c2d312c392c31372c31332c31372c31352c31372c2d312c31372c31372c32372c")
    (hex 5120 "352c32382c31372c2d312c222c0a6665726e733d2232342c39362c322c382c37322c39362c332c382c37392c39362c322c322c39362c39362c322c31342c3238302c3132382c322c382c3238382c3133362c332c322c3331322c3133362c342c382c3332302c3134342c342c382c3332382c3134342c352c31342c3436302c39362c322c382c3436372c39362c322c382c3534342c3434302c332c382c3630382c3434302c342c322c3435362c3538342c332c382c3436332c3538342c322c382c3437302c3538342c332c31342c3437372c3538342c332c382c3438342c3538342c322c322c3332302c3538342c332c382c3332382c3539322c332c31342c32")
    (hex 5376 "38362c3438302c342c382c3239342c3438302c332c382c3330322c3438302c332c322c3331302c3438302c322c382c3331382c3438302c332c382c37302c3430302c352c382c38302c3338342c342c31342c32362c3338342c342c382c222c0a737061776e3d22302c36342c3330302c372c3234302c32302c362c3330302c3133362c372c3432352c37302c342c3333352c38392c312c3536342c3436302c312c3538302c3436302c312c3539362c3436302c31312c3334342c3339322c312c3239372c3330392c312c3230382c3334332c312c3131362c3330302c312c32342c3333322c332c3334382c3335302c332c3137322c3238392c332c36302c3336")
    (hex 5632 "302c372c3533302c3333362c372c3636302c3333362c372c3430302c3537302c382c3436382c3537302c382c3330382c3437302c220a7d2c0a0a7b0a74696c65733d2232342c352c352c352c32302c2d312c31392c362c362c362c32382c2d312c32372c352c352c352c32312c2d312c32342c362c362c362c32312c2d312c222c0a737061776e3d22302c3537362c3332302c332c3234302c36322c322c3334332c36322c322c3436302c36322c312c3438302c36322c362c3138362c3136382c362c3331342c3136382c362c3434322c3136382c342c3234302c3331382c322c3334332c3331382c322c3436302c3331382c312c3438302c3331382c362c31")
    (hex 5888 "37302c3432342c362c3230322c3432342c362c3239382c3432342c362c3333302c3432342c362c3432362c3432342c362c3435382c3432342c222c0a6665726e733d22222e2e0a223338342c3233322c342c382c3339322c3234302c352c31342c3430302c3234302c342c382c3430382c3234302c332c382c3431362c3234302c332c31342c3432342c3234302c332c382c3433322c3234302c332c31342c3434302c3234302c332c382c3434382c3234302c332c382c3435362c3234302c332c31342c3436342c3234302c332c31342c3437322c3234302c332c382c3438302c3234302c342c31342c3438382c3234302c342c31342c3439362c3234302c35")
    (hex 6144 "2c382c3530342c3233322c352c31342c3235362c3233322c362c322c3236342c3234302c342c322c3237322c3234302c342c322c3238302c3234302c332c382c3238382c3234302c332c382c3239362c3234302c332c322c3330342c3234302c332c382c3331322c3234302c332c382c3332302c3234302c332c31342c3332382c3234302c332c322c3333362c3234302c332c382c3334342c3234302c332c382c3335322c3234302c362c31342c3336302c3234302c342c382c3336382c3234302c352c382c3337362c3233322c352c31342c3132382c3233322c332c322c3133362c3234302c342c322c3134342c3234302c342c382c3135322c3234302c33")
    (hex 6400 "2c322c3136302c3234302c332c382c3136382c3234302c332c382c3137362c3234302c332c322c3138342c3234302c332c382c3139322c3234302c332c382c3230302c3234302c332c322c3230382c3234302c332c382c3231362c3234302c332c322c3232342c3234302c342c322c3233322c3234302c342c382c3234302c3234302c352c382c3234382c3233322c362c382c222c0a7d2c0a0a7b0a7265663d223139322c33322c222c0a74696c65733d2231372c31322c31372c2d312c31372c31312c31372c2d312c31382c302c31362c2d312c31382c302c31362c2d312c31372c31352c31372c2d312c222c0a737061776e3d22302c3139322c3632302c")
    (hex 6656 "342c3139322c3132382c342c3230322c3239322c372c3135382c3338382c372c3233302c3338382c342c3139362c3436342c222c0a6669656c64733d223136392c3132302c342c312c31382c302c66616c73652c3134302c3331322c382c322c31382c3132382c66616c73652c220a7d2c0a0a7b0a7265663d2233322c3139322c222c0a74696c65733d2231372c31382c302c302c31362c2d312c342c372c302c302c31362c2d312c31372c31382c302c302c332c2d312c31372c31372c392c392c31372c2d312c222c0a6669656c64733d223236342c382c352c362c36342c36342c66616c73652c222c0a6665726e733d2238382c3233322c332c382c3130")
    (hex 6912 "342c3233322c322c392c3131322c3233322c332c382c3135322c3232342c332c392c3136382c3232342c322c392c3137362c3233322c332c382c222c0a737061776e3d22302c3630382c3332302c352c3239362c33322c352c3336302c36342c352c3432342c3235302c352c3438382c3132382c382c3239362c3130342c382c3430302c3136382c382c3438302c3233322c382c3331322c3239362c382c3331322c3336302c352c3239362c3136302c352c3336302c3139322c352c3432342c3132322c352c3438382c3235362c382c3432342c3130342c382c3330302c3136382c382c3338302c3233322c382c3531322c3239362c382c3431322c3336302c")
    (hex 7168 "220a7d2c0a0a7b0a74696c65733d2231352c2d312c31322c2d312c31332c2d312c31322c2d312c31312c2d312c302c2d312c322c2d312c32392c2d312c302c2d312c222c0a737061776e3d22302c36342c313038382c222c0a6669656c64733d2235302c38322c322c342c33382c35322c747275652c36382c3130382c312c342c33382c35322c747275652c35302c3430322c322c362c33382c35322c747275652c36382c3432382c312c362c33382c35322c747275652c222c0a74726967676572733d7b7b0a70617273652236342c3834302c36302c31302c302c222c0a66756e6374696f6e2829206372656174655f747261702839362c3838322920656e")
    (hex 7424 "640a7d2c7b0a70617273652236342c3932382c36302c31302c302c222c0a66756e6374696f6e2829206372656174655f747261702832302c39363029206372656174655f74726170283130382c39333029656e640a7d7d0a7d2c0a0a7b0a74696c65733d22302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c222c0a737061776e3d22302c36342c3837352c222c0a696e6b733d2239302c3131302c3131302c3132302c32362c3136362c34302c3139302c39352c3232362c3132382c3236302c302c3331362c37322c3334362c35302c3430302c3132382c3433302c302c3534302c37342c3630302c302c3630302c38")
    (hex 7680 "382c3634302c36302c3638302c38302c3730302c39302c3639302c3132302c3732302c302c3832302c3132382c3834302c302c3836302c32302c3839362c3130362c3838302c3132382c3839362c220a7d2c0a0a7b0a74696c65733d22302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c302c2d312c222c0a737061776e3d22302c36342c3837352c222c0a696e6b733d22302c3130302c3132382c3133322c302c3230302c3132382c3235362c302c3332302c3132382c3335322c34382c3335322c3132382c3435322c34382c3435322c38302c3530302c302c3530302c38302c3636342c38302c3536342c3132382c3630302c35")
    (hex 7936 "342c3636342c3132382c3733322c302c3733322c3132382c3738302c34302c3738302c3132382c3835342c38342c3835342c3132382c3839362c220a7d2c0a0a7b0a7265663d2235342c3134302c66616c73652c222c0a74696c65733d2232352c32352c32352c32352c32352c32352c32352c2d312c302c302c302c302c302c302c302c2d312c302c302c302c302c302c302c302c2d312c302c302c32362c32362c32362c32362c32362c2d312c31302c382c33302c33312c33302c33312c33302c2d312c222c0a737061776e3d22302c3132302c3631362c222c0a696e6b733d222d31302c3139322c3830302c3338342c3838302c3137362c3930302c3536")
    (hex 8192 "302c3530302c3137322c3533302c3430342c3336342c3434302c3431322c3436302c2d31302c2d31302c32302c3531322c39362c3433362c3134302c3438362c3231342c3438302c3236342c3631362c2d31302c3530302c36342c3536342c3238302c3336302c3239362c3434302c222c0a74726967676572733d7b7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a7570646174655f626f737328290a69662074253135303d3d30206f7220743d3d3230207468656e0a626f73732e776176653d34300a6d757369632833290a666f7220693d3239362c3837322c363420646f0a6372656174655f627562626c657328692c34")
    (hex 8448 "33362c31362c31342c322c34290a656e640a656e640a656e640a7d7d0a7d2c0a0a7b0a7265663d2236342c33322c222c0a74696c65733d2232322c2d312c32322c2d312c33302c2d312c32332c2d312c33312c2d312c222c0a737061776e3d22302c3234302c3132382c362c2d31352c3635302c362c3133382c3635302c362c2d31352c3531322c362c3133382c3531322c222c0a74726967676572733d7b7b0a7b7d2c0a66756e6374696f6e28290a6368616e67655f737461746528626f73732c2261637469766522290a626f73732e68703d330a6372656174655f627562626c6573286172672236342c3332302c32302c34302c322c332c22290a637265")
    (hex 8704 "6174655f696e6b28617267222d32302c3332302c3134362c3334302c31332c747275652c22290a626f73732e776176653d34300a6d757369632833290a656e640a7d2c7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a7570646174655f626f737328290a656e640a7d7d0a7d2c0a0a7b0a7265663d223139322c3730342c222c0a74696c65733d2231372c31352c31372c2d312c31372c31322c31372c2d312c31372c31322c31372c2d312c31372c31312c31372c2d312c31382c322c31362c2d312c31382c302c31362c2d312c222c0a737061776e3d22302c3139322c33322c312c3139302c3334362c312c3230322c3434")
    (hex 8960 "322c362c37382c36342c362c37382c3132382c362c37382c3139322c362c3330362c36342c362c3330362c3132382c362c3330362c3139322c222c0a6669656c64733d223137362c3332322c322c382c34302c32342c66616c73652c3139312c3235322c342c312c31322c302c66616c73652c222c0a74726967676572733d7b7b0a7b7d2c0a66756e6374696f6e28290a6372656174655f696e6b28617267222d31302c3736382c3339342c3736382c31332c22290a656e640a7d2c7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a6966207425323d3d30207468656e0a6372656174655f6578706c6f73696f6e28726e6428")
    (hex 9216 "333238292b3132302c726e6428323536292b3531322c726e642838292b38290a6372656174655f6578706c6f73696f6e28726e6428313238292b3132382c726e6428353132292c726e642838292b38290a656e640a6966207425666c7228726e64283130292b34293d3d30207468656e2073667828313429206164645f7368616b6528342920656e640a656e640a7d7d0a7d2c0a0a7b0a7265663d2236342c313038382c222c0a74696c65733d22302c2d312c302c2d312c31352c2d312c31322c2d312c31322c2d312c31332c2d312c31322c2d312c31312c2d312c31352c2d312c222c0a737061776e3d22302c36342c33322c362c2d31322c3634302c362c")
    (hex 9472 "3134302c3634302c222c0a6669656c64733d2233302c3531302c362c312c31302c302c66616c73652c37302c3435362c352c312c31302c302c66616c73652c32382c38302c332c332c34302c38302c747275652c34382c3132302c322c332c34302c38302c747275652c222c0a74726967676572733d7b7b0a7b7d2c0a66756e6374696f6e28290a6372656174655f696e6b28617267222d31302c313135302c3133382c313135322c31332c22290a6372656174655f747261702834302c31303230290a6372656174655f747261702839342c31303230290a656e640a7d2c7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a69")
    (hex 9728 "66207425343d3d30207468656e0a6372656174655f6578706c6f73696f6e28726e6428313238292c726e6428353132292b3234382c726e642838292b38290a6372656174655f6578706c6f73696f6e28726e6428313238292c726e6428353132292b3736302c726e642838292b38290a656e640a6966207425666c7228726e64283130292b34293d3d30207468656e2073667828313429206164645f7368616b6528342920656e640a656e640a7d2c7b0a70617273652236342c3338382c36302c34352c302c222c0a66756e6374696f6e28290a6372656174655f747261702832382c323134290a6372656174655f74726170283130302c323134290a656e64")
    (hex 9984 "0a7d7d0a7d2c0a0a7b0a7265663d223237362c36342c222c0a74696c65733d2231342c342c2d312c222c0a737061776e3d22302c3330302c3135302c222c0a6665726e733d22302c3130342c332c382c382c3130342c322c392c33322c3131322c322c382c34302c3131322c312c322c34392c3132382c322c382c35362c3132382c332c31342c39312c3132382c322c382c3130342c3132302c342c322c3131322c3130342c342c382c3132312c3130342c362c31342c3132382c3130342c362c382c3133352c3130342c352c392c3134322c3130342c342c31302c3134392c3130342c332c31352c3135362c3130342c322c372c3231382c3130342c322c37")
    (hex 10240 "2c3232352c3130342c332c31352c3233322c3130342c342c31302c3233392c3130342c352c392c3234362c3130342c362c382c222c0a74726967676572733d7b7b0a7b7d2c0a66756e6374696f6e28290a706c617965722e6f66663d747275650a656e640a7d2c7b0a706172736522302c302c302c302c312c222c0a66756e6374696f6e28290a6966207469746c6573207468656e0a706c617965722e6f66663d747275650a706c617965722e6469723d370a696620743d3d3830207468656e206d7573696328322920656e640a696620743e3d333020616e6420743c3d323030207468656e0a6368616e67655f737461746528706c617965722c227377696d")
    (hex 10496 "22290a706c617965722e76782d3d302e330a706c617965722e76792d3d302e330a656e640a656c73650a696620743d3d3230207468656e0a6372656174655f6578706c6f73696f6e28617267223235302c36342c33302c22290a736678283134290a6164645f7368616b652832290a6d757369632830290a706c617965722e6469723d360a706c617965722e76783d2d340a656e640a696620743d3d3630207468656e20706c617965722e6f66663d66616c736520656e640a656e640a656e640a7d2c7b0a70617273652237322c36342c33302c302c302c222c0a66756e6374696f6e28290a7469746c65733d747275650a743d300a656e640a7d7d0a7d0a0a")
    (hex 10752 "7d0a656e640a0a2d2d3e380a2d2d67616d65206c6f6f700a0a66756e6374696f6e205f696e697428290a0a6c6f61645f726f6f6d5f6461746128290a0a726f6f6d3d310a676f646d6f6465203d2066616c73650a0a777472667263203d20302e39340a0a67742c676d2c6465617468636f756e7465722c667265657a652c666164653d302c302c302c302c300a0a63616d782c63616d792c73686b782c73686b79203d20302c302c302c300a0a66616465733d7b0a3062313131313131313131313131313131312e312c0a3062303131313131313131313031313131312e312c0a3062303130313131313130313031313131312e312c0a306230313031313031")
    (hex 11008 "3130313031313131302e312c0a3062303130313130313030313031313031302e312c0a3062303030313130313030313030313031302e312c0a3062303030303130313030303030313031302e312c0a3062303030303030313030303030313030302e310a7d0a0a626f7373203d207b0a783d35322c0a793d3539322c0a68703d332c0a616e696d743d302c0a73746174653d2264656164222c0a776176653d302c0a626f78203d206e65775f626f78286172672234382c3537362c38302c3630382c22290a7d0a0a6c6f61645f726f6f6d28726f6f6d290a656e640a0a66756e6374696f6e205f75706461746528290a742b3d310a696620743e3d3330303030")
    (hex 11264 "207468656e20743d3020656e640a696620726f6f6d3e3120616e6420726f6f6d203c23726f6f6d73207468656e0a67742b3d310a69662067743d3d31383030207468656e2067743d3020676d2b3d3120656e640a656e640a696620667265657a65203e30207468656e20667265657a65202d3d20312072657475726e20656e640a696620666164653e30207468656e2072657475726e20656e640a0a7570646174655f7368616b6528290a7570646174655f706c6179657228706c61796572290a7570646174655f6f626a65637473286f626a65637473290a7570646174655f68617a617264732868617a61726473290a7570646174655f7061727469636c65")
    (hex 11520 "7328290a7570646174655f6578697428290a0a69662028706c617965722e696e76696e63693c3d3020616e64206e6f7420676f646d6f646529206f7220706c617965722e73746174653d3d2261747461636b22207468656e0a636f6c6c5f6f626a7328290a636865636b5f68617a6172645f636f6c6c732868617a61726473290a656e640a636f6c6c5f6578697428290a0a0a7570646174655f63616d65726128290a0a666f7220656e656d7920696e20616c6c286f626a656374732920646f0a696620656e656d792e6e616d65213d22706561726c2220616e6420656e656d792e6e616d65213d22636c616d22207468656e0a64657465637477616c6c7328")
    (hex 11776 "656e656d79290a656e640a656e640a0a7570646174655f7472696767657273287472696767657273290a656e640a0a0a66756e6374696f6e205f6472617728290a0a696620666164653e30207468656e0a696620666164653c3d23666164657320616e642066616465696e3d3d66616c7365207468656e0a66696c6c702866616465735b666164655d290a7265637466696c6c28302c302c636d6178782c636d6178792c31290a666164652b3d310a66696c6c7028290a72657475726e0a656c73650a66616465696e3d747275650a656e640a656e640a0a636c7328290a0a63616d6572612863616d782c63616d79290a0a647261775f6261636b67726f756e")
    (hex 12032 "6428290a647261775f666f726567726f756e6428290a647261775f6578697428290a647261775f7061727469636c657328290a647261775f68617a617264732868617a61726473290a647261775f6f626a65637473286f626a65637473290a647261775f706c6179657228706c61796572290a647261775f6678286678290a0a696620626f73732e7374617465213d226465616422207468656e20647261775f626f7373282920656e640a0a696620726f6f6d3e3120616e6420726f6f6d3c23726f6f6d73207468656e0a647261775f68756428290a656c73650a647261775f7469746c657328290a656e640a0a63616d65726128290a0a6966206661646569")
    (hex 12288 "6e20207468656e0a666164652d3d310a696620666164653e30207468656e0a66696c6c702866616465735b666164655d290a7265637466696c6c28302c302c636d6178782c636d6178792c31290a66696c6c7028290a656c73650a666164653d300a66616465696e3d66616c73650a656e640a656e640a656e640a0a0a0a66756e6374696f6e207570646174655f63616d65726128290a6c6f63616c20786f66662c796f66662c7064203d20302c302c706c617965722e6469720a6966207064203e3d203120616e64207064203c3d33207468656e20786f6666203d20313220656e640a6966207064203e3d203520616e64207064203c3d37207468656e2078")
    (hex 12544 "6f6666203d202d313220656e640a6966207064203c3d31206f72207064203d3d37207468656e20796f6666203d202d313220656e640a6966207064203e3d203320616e64207064203c3d35207468656e20796f6666203d20313220656e640a6c6f63616c2078706f696e74203d206d617828302c706c617965722e782d36342b28706c617965722e76782a3134292b786f6666290a6c6f63616c2079706f696e74203d206d617828302c706c617965722e792d36342b28706c617965722e76792a3134292b796f6666290a63616d78202b3d202878706f696e742d63616d78292a302e310a63616d79202b3d202879706f696e742d63616d79292a302e310a69")
    (hex 12800 "662063616d783e636d6178782d313237207468656e2063616d783d636d6178782d31323720656e640a69662063616d793e636d6178792d313237207468656e2063616d793d636d6178792d31323720656e640a63616d78202b3d73686b780a63616d79202b3d73686b790a656e640a0a0a66756e6374696f6e20647261775f6261636b67726f756e6428290a7265637466696c6c28302c302c636d6178782c636d6178792c31290a656e640a0a0a66756e6374696f6e20647261775f666f726567726f756e6428290a6c6f63616c206d6170782c6d617079203d20302c300a70616c2831302c30290a666f72206920696e20616c6c28726f6f6d74696c657329")
    (hex 13056 "20646f0a69662069203d3d202d31207468656e0a6d6170783d300a6d6170792b3d3132380a656c73650a6d61702828692538292a31362c666c7228692f38292a31362c6d6170782c6d6170792c31362c31362c307831290a6d6170782b3d3132380a656e640a656e640a70616c28290a656e640a0a66756e6374696f6e207570646174655f6f626a65637473286f626a65637473290a666f7220656e656d7920696e20616c6c286f626a656374732920646f0a656e656d792e75706461746528656e656d79290a656e640a656e640a0a66756e6374696f6e207570646174655f68617a617264732868617a61726473290a666f72207020696e20616c6c286861")
    (hex 13312 "7a617264732920646f0a702e7570646174652870290a656e640a656e640a0a66756e6374696f6e20636865636b5f68617a6172645f636f6c6c732868617a61726473290a666f72207020696e20616c6c2868617a617264732920646f0a702e636f6c6c2870290a656e640a656e640a0a66756e6374696f6e20647261775f68617a617264732868617a61726473290a666f72207020696e20616c6c2868617a617264732920646f0a702e647261772870290a656e640a656e640a0a0a0a66756e6374696f6e206372656174655f74726967676572287265662c65786563290a6c6f63616c2074203d7b0a783d7265665b315d206f7220302c0a793d7265665b32")
    (hex 13568 "5d206f7220302c0a70726f783d7265665b335d206f7220312c0a743d7265665b345d206f7220302c0a6163746976653d7265665b355d206f7220312c0a657865633d657865630a7d0a6164642874726967676572732c74290a656e640a0a66756e6374696f6e207570646174655f7472696767657273287472696767657273290a666f72207472696720696e20616c6c2874726967676572732920646f0a6c6f63616c206b696c6c3d66616c73650a696620747269672e70726f783e30207468656e0a6b696c6c3d747275650a6966206469737428706c617965722e782c706c617965722e792c747269672e782c747269672e79293c3d747269672e70726f78")
    (hex 13824 "207468656e0a747269672e6163746976653d310a656e640a656e640a0a696620747269672e6163746976653d3d31207468656e0a696620747269672e743e30207468656e0a747269672e742d3d310a656c73650a747269672e74203d20300a747269672e6578656328290a6966206b696c6c207468656e2064656c2874726967676572732c747269672920656e640a656e640a656e640a656e640a656e640a0a66756e6374696f6e207570646174655f7368616b6528290a6966206162732873686b78292b6162732873686b79293c302e35207468656e0a73686b782c73686b793d302c300a656c73650a73686b782a3d2d302e352d726e6428302e32290a73")
    (hex 14080 "686b792a3d2d302e352d726e6428302e32290a656e640a656e640a0a66756e6374696f6e20647261775f6f626a65637473286f626a65637473290a666f7220656e656d7920696e20616c6c286f626a656374732920646f0a656e656d792e6472617728656e656d79290a656e640a656e640a0a66756e6374696f6e20647261775f68756428290a666f7220693d3130362c3132322c3820646f0a636972632863616d782b692d73686b782c63616d792b362d73686b792c332e352c30290a656e640a6c6f63616c2063783d3130360a6c6f63616c20636f6c3d7465726e61727928743c333020616e64207425343d3d302c372c38290a666f7220693d312c706c")
    (hex 14336 "617965722e687020646f0a6369726366696c6c2863616d782b63782d73686b782c63616d792b362d73686b792c322e352c636f6c290a707365742863616d782b63782d312d73686b782c63616d792b342d73686b792c37290a63782b3d380a656e640a0a626f6c647072696e742874696d657228292c63616d782b322d73686b782c63616d792b3132312d73686b79290a656e640a0a66756e6374696f6e20647261775f7469746c657328290a696620706c617965722e793e3d363020616e6420743e3d363020616e6420726f6f6d3d3d31207468656e0a626f6c647072696e742822e2ac85efb88fe29ea1efb88fe2ac86efb88fe2ac87efb88f3a206d6f76")
    (hex 14592 "65222c33322c3430290a626f6c647072696e742822e29d8e2ff09f85beefb88f2028686f6c64293a2061747461636b222c32302c3530290a656e640a6966207469746c657320616e6420743e3d3830207468656e0a696620726f6f6d3d3d31207468656e0a626f6c647072696e742822732077206f207220642066206920732068222c3135352c3630290a656c73650a6c6f63616c207473746172732c20647374617273203d20312c310a696620676d203c3135207468656e0a747374617273203d20320a696620676d3c3130207468656e0a747374617273203d20330a656e640a656e640a6966206465617468636f756e746572203c3131207468656e0a64")
    (hex 14848 "73746172733d320a6966206465617468636f756e746572203c36207468656e0a6473746172733d330a656e640a656e640a0a72656374286172672232382c32372c39362c39362c22290a626f6c647072696e742822636f6e67726174756c6174696f6e73222c33332c33322c3130290a626f6c647072696e74282274696d653a20222e2e74696d657228292c34332c3432290a0a666f7220693d312c3320646f0a6c6f63616c207378203d2034302b28692a3130290a696620693e747374617273207468656e0a7072696e742822e29885222c73782c35322c36290a656c73650a626f6c647072696e742822e29885222c73782c35322c3130290a656e640a65")
    (hex 15104 "6e640a0a626f6c647072696e7428226465617468733a20222e2e6465617468636f756e7465722c34352c3632290a0a666f7220693d312c3320646f0a6c6f63616c207378203d2034302b28692a3130290a696620693e647374617273207468656e0a7072696e742822e29885222c73782c37322c36290a656c73650a626f6c647072696e742822e29885222c73782c37322c3130290a656e640a656e640a0a626f6c647072696e7428227468616e6b7320666f72222c34332c3832290a626f6c647072696e742822706c6179696e6721222c34382c3839290a656e640a656e640a656e640a0a66756e6374696f6e20647261775f667828667873290a666f7220")
    (hex 15360 "667820696e20616c6c2866782920646f0a66782e64726177286678290a656e640a656e640a0a66756e6374696f6e206e6578745f726f6f6d28290a726f6f6d2b3d310a6c6f61645f726f6f6d28726f6f6d290a656e640a0a0a66756e6374696f6e206c6f61645f726f6f6d28726d290a743d300a0a6f626a656374733d7b7d0a66783d7b7d0a7061727469636c65733d7b7d0a74726967676572733d7b7d0a68617a617264733d7b7d0a0a6c6f63616c20723d726f6f6d735b726d5d0a0a6c6f63616c20726f6f6d7265663d7b36342c36342c66616c73657d0a696620722e726566207468656e20726f6f6d7265663d706172736528722e7265662920656e64")
    (hex 15616 "0a0a6c6f63616c207078203d20726f6f6d7265665b315d0a6c6f63616c207079203d20726f6f6d7265665b325d0a706c61796572203d206372656174655f706c617965722870782c7079290a63616d783d6d617828302c70782d3534290a63616d793d6d617828302c70792d3634290a0a726f6f6d74696c65733d706172736528722e74696c6573290a726f6f6d726f7773203d20300a666f72206920696e20616c6c28726f6f6d74696c65732920646f0a69662069203d3d202d31207468656e0a726f6f6d726f77732b3d310a656e640a656e640a0a726f6f6d636f6c73203d202823726f6f6d74696c65732d726f6f6d726f7773292f726f6f6d726f7773")
    (hex 15872 "0a0a636d617878203d20726f6f6d636f6c732a3132382d310a636d617879203d20726f6f6d726f77732a3132382d310a0a737061776e6c69737428722e737061776e290a0a696620726f6f6d7265665b335d207468656e0a657869742e73746174653d22636c6f736564220a657869742e636f6d6261743d747275650a656e640a0a666f72207420696e20616c6c28722e74726967676572732920646f0a6372656174655f7472696767657228745b315d2c745b325d290a656e640a0a696620722e6669656c6473213d6e696c207468656e0a6c6f63616c2066203d20706172736528722e6669656c6473290a666f7220693d312c23662c3720646f0a637265")
    (hex 16128 "6174655f6669656c6428665b695d2c665b692b315d2c665b692b325d2c665b692b335d2c665b692b345d2c665b692b355d2c665b692b365d290a656e640a656e640a0a696620722e696e6b73213d6e696c207468656e0a6c6f63616c20696e6b73203d20706172736528722e696e6b73290a666f7220693d312c23696e6b732c3420646f0a6372656174655f696e6b28696e6b735b695d2c696e6b735b692b315d2c696e6b735b692b325d2c696e6b735b692b335d290a656e640a656e640a0a696620722e6665726e73213d6e696c207468656e0a6c6f63616c206673203d20706172736528722e6665726e73290a666f7220693d312c2366732c3420646f0a")
    (hex 16384 "6372656174655f6665726e2866735b695d2c66735b692b315d2c66735b692b325d2c66735b692b335d290a656e640a656e640a0a666164653d310a0a656e640a0a0a2d2d3e380a2d2d706c617965722d2d0a0a66756e6374696f6e206372656174655f706c6179657228782c79290a6c6f63616c20703d6e65775f6f626a65637428782c792c22706c6179657222290a702e6469723d320a702e68703d330a702e6368617267653d300a702e696e76696e63693d300a702e636f6f6c646f776e3d300a702e666c6173683d300a702e626967626f783d66616c73650a702e7470737064203d20330a0a702e7370725f696e666f3d7b0a69646c65203d207b0a75")
    (hex 16640 "70203d20706172736522372c33382c372c33392c222c0a6469616775203d2070617273652233322c33362c33322c33342c222c0a6469616764203d2070617273652234302c34322c34302c34342c222c0a72696768743d70617273652231362c31382c31362c32302c222c0a64743d302e330a7d2c0a7377696d203d207b0a7570203d2070617273652233382c33392c222c0a6469616775203d2070617273652233362c33342c222c0a6469616764203d2070617273652234322c34342c222c0a72696768743d70617273652231382c32302c222c0a64743d302e30350a7d2c0a636861726765203d207b0a7570203d207b33387d2c0a6469616775203d207b")
    (hex 16896 "33327d2c0a6469616764203d207b34327d2c0a72696768743d7b31387d2c0a64743d302e320a7d2c0a61747461636b203d207b0a7570203d207b31357d2c0a6469616775203d207b31317d2c0a6469616764203d207b31317d2c0a72696768743d7b31337d2c0a64743d302e320a7d2c0a68757274203d207b0a68757274203d207b34367d2c0a64743d302e320a7d2c0a64656164203d207b0a68757274203d207b34367d2c0a64743d302e320a7d0a7d0a702e6162735f626f783d66756e6374696f6e28617474290a6c6f63616c20622c6d782c6d792c7062203d20352c302c302c702e626967626f7820616e64206174740a69662061747420616e642070")
    (hex 17152 "2e73746174653d3d2261747461636b22207468656e0a623d7465726e6172792870622c31342c38290a656e640a0a696620702e6469723d3d2030206f7220702e6469723d3d34207468656e0a6d783d310a6966207062207468656e0a6d793d350a656e640a656c7365696620702e6469723d3d32206f7220702e6469723d3d36207468656e0a6d793d310a6966207062207468656e0a6d783d350a656e640a656c73656966207062207468656e0a6d782c6d793d352c350a656e640a0a72657475726e206e65775f626f7828702e782d622b6d782c702e792d622b6d792c702e782b622d6d782c702e792b622d6d79290a656e640a0a72657475726e20700a65")
    (hex 17408 "6e640a0a0a66756e6374696f6e207570646174655f706c617965722870290a702e616e696d742b3d302e30310a0a6c6f63616c207374617465203d20702e73746174650a0a69662073746174653d3d226465616422207468656e0a702e76792b3d302e30340a6170706c795f6672696374696f6e28702c777472667263290a69662061627328702e616e696d742f302e30312925323d3d30207468656e20702e666c617368203d20302e3120656e640a696620702e616e696d743e3d31207468656e206c6f61645f726f6f6d28726f6f6d2920656e640a0a656c73650a0a696620702e696e76696e63693e30207468656e0a702e696e76696e6369202d3d2031")
    (hex 17664 "0a656c736520702e696e76696e6369203d20300a656e640a6c6f63616c20626c2c62722c62752c62642c62782c627a0a6966206e6f7420706c617965722e6f6666207468656e0a69662062746e223022207468656e20626c3d7472756520656e640a69662062746e223122207468656e2062723d7472756520656e640a69662062746e223222207468656e2062753d7472756520656e640a69662062746e223322207468656e2062643d7472756520656e640a69662062746e223422207468656e20627a3d7472756520656e640a69662062746e223522207468656e2062783d7472756520656e640a656e640a69662073746174653d3d226875727422207468")
    (hex 17920 "656e0a696620702e636f6f6c646f776e203e2030207468656e0a626c2c62722c62752c6264203d2066616c73652c2066616c73652c2066616c73652c2066616c73650a656c73650a702e696e76696e6369203d2036300a6368616e67655f737461746528702c2269646c6522290a656e640a656e640a696620702e636f6f6c646f776e203e2030207468656e0a702e636f6f6c646f776e2d3d302e310a627a2c6278203d2066616c73652c66616c73650a656c73650a702e636f6f6c646f776e3d300a656e640a69662073746174653d3d2263686172676522616e64206e6f7428627a206f7220627829207468656e0a696620702e6368617267653e3d312074")
    (hex 18176 "68656e0a7366782834290a6372656174655f627562626c657328702e782c702e792c726e642834292b702e6368617267652c342c312c702e6368617267652b31290a696620702e6368617267653e3d33207468656e20702e626967626f783d7472756520656e640a6368616e67655f737461746528702c2261747461636b22290a656c73650a6368616e67655f737461746528702c2769646c6527290a656e640a656e640a7374617465203d20702e73746174650a69662073746174653d3d2261747461636b22207468656e0a696620702e636861726765203e2030207468656e0a6c6f63616c2064203d20702e6469720a6c6f63616c2061747461636b7370")
    (hex 18432 "643d380a696620643d3d30206f7220643d3d31206f7220643d3d37207468656e20702e76792d3d61747461636b73706420656e640a696620643e3d3120616e6420643c3d33207468656e20702e76782b3d61747461636b73706420656e640a696620643e3d3320616e6420643c3d35207468656e20702e76792b3d61747461636b73706420656e640a696620643e3d35207468656e20702e76782d3d61747461636b73706420656e640a702e6368617267652d3d302e31350a6170706c795f616363656c28702c702e74707370642b28666c7228702e636861726765292a312e3529290a69662061627328702e616e696d742f302e30312925323d3d30207468")
    (hex 18688 "656e09702e666c617368203d20302e3120656e640a6164645f7368616b6528302e33290a656c73650a702e636861726765203d20300a702e636f6f6c646f776e203d20320a696620706c617965722e696e76696e63693c33207468656e20706c617965722e696e76696e63693d313520656e640a702e626967626f78203d2066616c73650a6368616e67655f737461746528702c2769646c6527290a656e640a656c73650a6966202873746174653d3d226368617267652220616e64207425333d3d3029206f72207374617465213d2263686172676522207468656e202d2d6f6e6c7920636865636b20646972656374696f6e20657665727920746872656520")
    (hex 18944 "6672616d6573206966206368617267696e672820746f206d616b652061696d696e67206c65737320666964646c79290a736574646972656374696f6e28702c626c2c62722c62752c6264290a656e640a69662028626c206f72206272206f72206275206f722062642920616e64206e6f7428627a206f7220627829207468656e0a6c6f63616c20706c6163633d302e350a6368616e67655f737461746528702c227377696d22290a696620626c207468656e20702e76782d3d706c61636320656e640a6966206272207468656e20702e76782b3d706c61636320656e640a6966206275207468656e20702e76792d3d706c61636320656e640a69662062642074")
    (hex 19200 "68656e20702e76792b3d706c61636320656e640a6170706c795f616363656c28702c702e7470737064290a656c73650a69662028627a206f722062782920616e64206e6f742028702e636f6f6c646f776e203e3029207468656e0a6368616e67655f737461746528702c2263686172676522290a696620702e616e696d743e3d302e38207468656e0a702e636861726765203d20300a7366782835290a6164645f7368616b652833290a702e636f6f6c646f776e203d20320a6368616e67655f737461746528702c2769646c6527290a656c7365696620702e616e696d743e3d302e323720616e6420702e636861726765203c33207468656e0a702e63686172")
    (hex 19456 "67653d330a7366782833290a656c7365696620702e616e696d743e3d302e313520616e6420702e636861726765203c32207468656e0a702e666c6173683d302e320a702e6368617267653d320a7366782832290a656c7365696620702e616e696d743e3d302e303320616e6420702e636861726765203c31207468656e0a702e666c6173683d302e320a702e6368617267653d310a7366782831290a656e640a696620702e6368617267653d3d3320616e642061627328702e616e696d742f302e30312925353d3d3020616e6420702e616e696d743c302e3735207468656e0a702e666c617368203d20302e320a656e640a0a656c7365696620737461746521")
    (hex 19712 "3d27687572742720616e64206e6f74207469746c6573207468656e0a6368616e67655f737461746528702c2269646c6522290a656e640a656e640a656e640a656e640a69662073746174653d3d2261747461636b22207468656e0a6c6f63616c20786d3d302e330a0a696620702e6469722532213d30207468656e20786d3d2d302e3320656e640a6372656174655f7061727469636c6528702e782b702e76782a322e322c702e792b702e76792a322e322c702e76792a302e332c702e76782a786d2c74727565290a6372656174655f7061727469636c6528702e782b702e76782a322e322c702e792b702e76792a322e322c702e76792a2d302e332c702e76")
    (hex 19968 "782a2d786d2c74727565290a656e640a6170706c795f6672696374696f6e28702c777472667263290a6d6f76652870290a6966206e6f7420706c617965722e6f6666207468656e0a64657465637477616c6c732870290a656e640a656e640a0a66756e6374696f6e20647261775f706c617965722870290a6c6f63616c2073746174653d702e73746174650a6c6f63616c2073696e666f3d702e7370725f696e666f5b73746174655d0a6c6f63616c20666c6970782c666c6970792c737072772c737072682c786f66662c796f66662c73707269746573203d2066616c73652c66616c73652c322c322c2d342c2d382c7b7d0a0a69662073746174653d3d2268")
    (hex 20224 "75727422206f722073746174653d3d226465616422207468656e0a73707269746573203d2073696e666f2e687572740a656c73650a6c6f63616c2064203d20702e6469720a696620643d3d30206f7220643d3d34207468656e2073707269746573203d2073696e666f2e757020737072773d3120656e640a696620643d3d31206f7220643d3d37207468656e2073707269746573203d2073696e666f2e646961677520786f66663d2d3820656e640a696620643d3d32206f7220643d3d36207468656e2073707269746573203d2073696e666f2e726967687420737072683d3120786f66663d2d3820796f66663d2d3420656e640a696620643d3d33206f7220")
    (hex 20480 "643d3d35207468656e2073707269746573203d2073696e666f2e646961676420786f66663d2d3820656e640a696620643d3d34206f72202828643d3d33206f7220643d3d352920616e642073746174653d3d2261747461636b2229207468656e20666c6970793d7472756520656e640a696620643e3d35207468656e20666c6970783d7472756520656e640a656e640a6c6f63616c2073707269203d20737072697465735b666c7228702e616e696d742f73696e666f2e6474292523737072697465732b315d0a69662028702e696e76696e63693e3020616e6420666c7228702e696e76696e63692533293d3d3029207468656e0a656c73650a6c6f63616c20")
    (hex 20736 "6663203d20370a69662073746174653d3d226465616422207468656e2066633d3820656e640a6c6f63616c206f63203d20300a696620702e666c6173683e30207468656e206f63203d20666320656e640a647261776f75746c696e6528737072692c702e782b786f66662c702e792b796f66662c737072772c737072682c666c6970782c666c6970792c6f63290a666c6173686f626a65637428702c6663290a73707228737072692c702e782b786f66662c702e792b796f66662c737072772c737072682c666c6970782c666c697079290a656e640a70616c28290a656e640a0a66756e6374696f6e20636f6c6c5f6f626a7328290a666f72206520696e2061")
    (hex 20992 "6c6c286f626a656374732920646f0a0a6c6f63616c206174743d7465726e61727928706c617965722e73746174653d3d2261747461636b2220616e64206e6f7420652e696e76696e63692c747275652c66616c7365290a0a0a696620636f6c6c28652e6162735f626f7828292c706c617965722e6162735f626f78286174742929207468656e0a6c6f63616c206e616d65203d20652e6e616d650a6966206e616d653d3d226d696e6522207468656e206368616e67655f737461746528652c226465746f6e617465222920736678283929656e640a0a696620706c617965722e73746174653d3d2261747461636b22207468656e0a696620652e696e76696e63")
    (hex 21248 "69207468656e0a696620706c617965722e696e76696e63693e30207468656e2072657475726e20656e640a6966206e616d65213d22636c616d22207468656e20626f756e636528652c706c617965722e76782a302e362c706c617965722e76792a302e362920656e640a63616e63656c5f61747461636b28290a626f756e63655f72656c617469766528706c617965722c652c33290a656c73650a6b696c6c5f6f626a6563742865290a656e640a656c7365696620706c617965722e7374617465213d226875727422207468656e0a6966206e616d65213d22636c616d22207468656e20626f756e636528652c706c617965722e76782c706c617965722e7679")
    (hex 21504 "2920656e640a6966206e616d65213d226d696e6522207468656e0a6966206e6f7420286e616d653d3d22636c616d2220616e6420652e73746174653d3d2269646c652229207468656e0a696620706c617965722e696e76696e63693e30207468656e2072657475726e20656e640a687572745f706c6179657228706c61796572290a656e640a656e640a626f756e63655f72656c617469766528706c617965722c652c33290a6966206e616d653d3d22706561726c22207468656e206b696c6c5f6f626a65637428652920656e640a656e640a656e640a656e640a656e640a0a0a66756e6374696f6e20687572745f706c617965722870290a696620702e7374")
    (hex 21760 "61746520213d20226465616422207468656e0a702e68702d3d310a6372656174655f627562626c657328702e782c702e792c726e642833292b332c382c322c34290a667265657a653d330a7366782836290a6164645f7368616b65283130290a696620702e68703c3d30207468656e0a6465617468636f756e7465722b3d310a6368616e67655f737461746528702c226465616422290a656c73650a702e636861726765203d20300a702e636f6f6c646f776e203d20330a6368616e67655f737461746528702c226875727422290a656e640a656e640a656e640a0a66756e6374696f6e2063616e63656c5f61747461636b28290a6368616e67655f73746174")
    (hex 22016 "6528706c617965722c2269646c6522290a6164645f7368616b652833290a7366782839290a706c617965722e636861726765203d20300a706c617965722e636f6f6c646f776e203d20320a706c617965722e666c617368203d20300a706c617965722e626967626f783d66616c73650a666f7220693d312c726e642834292b3320646f0a6372656174655f7061727469636c6528706c617965722e782c706c617965722e792c726e642833292b2d322c726e642833292b2d322c74727565290a656e640a696620706c617965722e696e76696e63693c33207468656e20706c617965722e696e76696e63693d313520656e640a656e640a0a2d2d3e380a2d2d6f")
    (hex 22272 "626a656374732d2d0a0a0a66756e6374696f6e206e65775f6f626a65637428782c792c6e616d652c7570646174652c64726177290a72657475726e207b783d782c793d792c76783d302c76793d302c616e696d743d302c73746174653d2269646c65222c6e616d653d6e616d652c7570646174653d7570646174652c647261773d647261777d0a656e640a0a66756e6374696f6e206372656174655f736e617070657228782c79290a6c6f63616c20653d6e65775f6f626a65637428782c792c22736e6170706572222c7570646174655f736e61707065722c647261775f736e6170706572290a652e6469723d300a652e6163746976653d66616c73650a0a65")
    (hex 22528 "2e7370725f696e666f3d7b0a69646c65203d207b0a7570203d207b312c327d2c0a64696167203d207b332c347d2c0a72696768743d7b352c367d2c0a64743d302e30320a7d0a7d0a652e6162735f626f783d66756e6374696f6e28290a72657475726e206e65775f626f7828652e782d332c652e792d332c652e782b332c652e792b33290a656e640a616464286f626a656374732c2065290a72657475726e20650a656e640a0a66756e6374696f6e206372656174655f7363686f6f6c28782c79290a666f7220693d312c3620646f0a6c6f63616c20613d726e642831290a6c6f63616c20643d726e64283230290a6c6f63616c2073783d782b642a636f7328")
    (hex 22784 "61290a6c6f63616c2073793d792b642a73696e2861290a6372656174655f736e61707065722873782c7379290a656e640a656e640a0a0a66756e6374696f6e207570646174655f736e61707065722865290a652e616e696d742b3d302e30310a6c6f63616c2064203d206469737428652e782c652e792c706c617965722e782c706c617965722e79290a6966206e6f7420652e616374697665207468656e0a696620643c3d313230207468656e20652e6163746976653d7472756520656e640a656c73650a6c6f63616c207370642c627566663d302e312c32300a696620643c3d3230207468656e20627566663d3420656e640a6c6f63616c206c2c722c752c")
    (hex 23040 "640a696620706c617965722e782d62756666203e20652e78207468656e20652e7678202b3d73706420723d7472756520656e640a696620706c617965722e782b62756666203c20652e78207468656e20652e7678202d3d737064206c3d7472756520656e640a696620706c617965722e792d62756666203e20652e79207468656e20652e7679202b3d73706420643d7472756520656e640a696620706c617965722e792b62756666203c20652e79207468656e20652e7679202d3d73706420753d7472756520656e640a6170706c795f616363656c28652c31290a736574646972656374696f6e28652c6c2c722c752c64290a0a6d6f76652865290a656e640a")
    (hex 23296 "656e640a0a66756e6374696f6e20647261775f736e61707065722865290a6c6f63616c2073696e666f2c666c6970782c666c6970792c737072697465732c643d652e7370725f696e666f5b652e73746174655d2c66616c73652c66616c73652c7b7d2c652e6469720a0a696620643d3d30206f7220643d3d34207468656e2073707269746573203d2073696e666f2e75702020656e640a696620643d3d31206f7220643d3d33206f7220643d3d35206f7220643d3d37207468656e2073707269746573203d2073696e666f2e6469616720656e640a696620643d3d32206f7220643d3d36207468656e2073707269746573203d2073696e666f2e726967687420")
    (hex 23552 "656e640a696620643e3d3320616e6420643c3d35207468656e2020666c6970793d7472756520656e640a696620643e3d35207468656e20666c6970783d7472756520656e640a0a6c6f63616c2073707269203d20737072697465735b666c7228652e616e696d742f73696e666f2e6474292523737072697465732b315d0a647261776f75746c696e6528737072692c652e782d342c652e792d342c312c312c666c6970782c666c6970792c302c74727565290a656e640a0a66756e6374696f6e206372656174655f70756666657228782c79290a6c6f63616c20653d6e65775f6f626a65637428782c792c22707566666572222c7570646174655f7075666665")
    (hex 23808 "722c647261775f707566666572290a652e696e76696e63693d66616c73650a0a652e7370725f696e666f3d7b0a69646c65203d207b0a73707269746573203d207b3131302c3131317d2c0a64743d302e30320a7d2c0a707566666564203d207b0a73707269746573203d207b37387d2c0a64743d302e350a7d0a7d0a652e6162735f626f783d66756e6374696f6e28290a6c6f63616c2073697a65203d207465726e61727928652e73746174653d3d22707566666564222c372c33290a72657475726e206e65775f626f7828652e782d73697a652c652e792d73697a652c652e782b73697a652c652e792b73697a65290a656e640a616464286f626a65637473")
    (hex 24064 "2c2065290a72657475726e20650a656e640a0a0a66756e6374696f6e207570646174655f7075666665722865290a652e616e696d742b3d302e30310a6c6f63616c206f733d2069735f6f666673637265656e28652c3830290a6966206f73207468656e2072657475726e20656e640a6c6f63616c207374617465203d20652e73746174650a6c6f63616c20737064203d207465726e6172792873746174653d3d22707566666564222c302e30362c302e31290a0a696620652e616e696d743e312e3220616e642073746174653d3d2269646c6522207468656e0a6368616e67655f737461746528652c2270756666656422290a652e696e76696e63693d747275")
    (hex 24320 "650a6966206e6f74206f73207468656e207366782832332920656e640a656e640a696620652e616e696d743e302e373520616e642073746174653d3d2270756666656422207468656e0a6368616e67655f737461746528652c2269646c6522290a652e696e76696e63693d66616c73650a6966206e6f74206f73207468656e207366782832342920656e640a656e640a6966206469737428706c617965722e782c706c617965722e792c652e782c652e79293c343820616e642073746174653d3d2269646c6522207468656e20737064202a3d2d3120656e640a696620706c617965722e782d38203e20652e78207468656e20652e7678202b3d73706420656e")
    (hex 24576 "640a696620706c617965722e782b38203c20652e78207468656e20652e7678202d3d73706420656e640a696620706c617965722e792d38203e20652e79207468656e20652e7679202b3d73706420656e640a696620706c617965722e792b38203c20652e79207468656e20652e7679202d3d73706420656e640a0a6170706c795f616363656c28652c31290a6d6f76652865290a656e640a0a66756e6374696f6e20647261775f7075666665722865290a6c6f63616c2073696e666f3d652e7370725f696e666f5b652e73746174655d0a6c6f63616c2073707269746573203d2073696e666f2e737072697465730a6c6f63616c20666c6970782c737072772c")
    (hex 24832 "737072682c786f66662c796f6666203d207465726e61727928706c617965722e783e652e782c747275652c66616c7365292c312c312c2d342c2d340a0a696620652e73746174653d3d2270756666656422207468656e20786f66662c796f66662c737072772c737072682c666c697078203d202d382c2d382c322c322c6e6f7420666c6970782020656e640a6c6f63616c2073707269203d20737072697465735b666c7228652e616e696d742f73696e666f2e6474292523737072697465732b315d0a647261776f75746c696e6528737072692c652e782b786f66662c652e792b796f66662c737072772c737072682c666c6970782c66616c73652c302c7472")
    (hex 25088 "7565290a656e640a0a66756e6374696f6e206372656174655f737175696428782c792c736861726b290a6c6f63616c20653d6e65775f6f626a65637428782c792c227371756964222c7570646174655f73717569642c647261775f7371756964290a652e75703d66616c73650a652e696e76696e63693d66616c73650a6c6f63616c2073612c73623d2037362c37370a696620736861726b207468656e0a652e6e616d652c652e75702c73612c73623d22736861726b222c747275652c37342c39300a656e640a0a652e7370725f696e666f3d7b0a69646c65203d207b0a73707269746573203d207b73617d2c0a64743d302e30320a7d2c0a7377696d203d20")
    (hex 25344 "7b0a73707269746573203d207b73612c73627d2c0a64743d360a7d0a7d0a652e6162735f626f783d66756e6374696f6e28290a6c6f63616c2078612c79613d332c370a696620652e6e616d653d3d22736861726b22207468656e2078612c79613d372c3320656e640a72657475726e206e65775f626f7828652e782d78612c652e792d79612c652e782b78612c652e792b7961290a656e640a616464286f626a656374732c2065290a72657475726e20650a656e640a0a66756e6374696f6e206372656174655f736861726b28782c79290a6372656174655f737175696428782c792c74727565290a656e640a0a66756e6374696f6e207570646174655f7371")
    (hex 25600 "7569642865290a652e616e696d742b3d310a696620652e6e616d653d3d22737175696422207468656e0a652e75703d7465726e61727928652e76793c302c747275652c66616c7365290a652e696e76696e63693d7465726e617279282828706c617965722e793e652e792d3320616e64206e6f7420652e757029206f722028706c617965722e793c652e792b3320616e6420652e757029292c747275652c66616c7365290a0a656c73650a652e75703d7465726e61727928652e76783c3d302c747275652c66616c7365290a656e640a0a696620652e73746174653d3d2769646c6527207468656e0a6170706c795f6672696374696f6e28652c777472667263")
    (hex 25856 "290a696620652e616e696d743e3330207468656e206368616e67655f737461746528652c277377696d272920656e640a656c73650a696620652e616e696d743e313230207468656e206368616e67655f737461746528652c2769646c65272920656e640a696620652e6e616d653d3d22737175696422207468656e0a652e76792b3d7465726e61727928652e75702c2d302e312c302e31290a656c73650a652e76782b3d7465726e61727928652e75702c2d302e312c302e31290a656e640a6170706c795f616363656c28652c312e35290a656e640a6d6f76652865290a656e640a0a66756e6374696f6e20647261775f73717569642865290a6c6f63616c20")
    (hex 26112 "73696e666f203d20652e7370725f696e666f5b652e73746174655d0a6c6f63616c2073707269746573203d2073696e666f2e737072697465730a6c6f63616c2073707269203d20737072697465735b666c7228652e616e696d742f73696e666f2e6474292523737072697465732b315d0a6c6f63616c20666c6970792c666c6970782c78612c79612c73782c7379203d2066616c73652c66616c73652c332c372c312c320a696620652e6e616d653d3d22737175696422207468656e0a666c6970793d7465726e61727928652e75702c66616c73652c74727565290a656c73650a666c6970783d7465726e61727928652e75702c747275652c66616c7365290a")
    (hex 26368 "78612c79612c73782c73793d372c332c322c310a656e640a647261776f75746c696e6528737072692c652e782d78612c652e792d79612c73782c73792c666c6970782c666c6970792c302c74727565290a656e640a0a66756e6374696f6e206372656174655f7370696b657928782c792c6d696e65290a6c6f63616c20653d6e65775f6f626a65637428782c792c227370696b6579222c7570646174655f7370696b65792c647261775f7370696b6579290a652e737072693d32320a652e626f623d747275650a652e666c6173683d300a652e696e76696e63693d747275650a0a652e73656564203d20666c7228726e6428333029290a652e6162735f626f78")
    (hex 26624 "3d66756e6374696f6e28290a72657475726e206e65775f626f7828652e782d332c652e792d332c652e782b332c652e792b33290a656e640a6966206d696e65207468656e20652e6e616d65203d20226d696e652220652e737072693d313020656e640a616464286f626a656374732c2065290a72657475726e20650a656e640a0a66756e6374696f6e206372656174655f6d696e6528782c79290a72657475726e206372656174655f7370696b657928782c792c74727565290a656e640a0a66756e6374696f6e206372656174655f6669656c6428782c792c636f6c732c726f77732c7873706163652c7973706163652c6d696e65290a6c6f63616c2079706f")
    (hex 26880 "73203d20790a666f7220693d312c636f6c7320646f0a666f7220693d312c726f777320646f0a6372656174655f7370696b657928782c79706f732c6d696e65290a79706f732b3d7973706163650a656e640a782b3d7873706163650a79706f733d790a656e640a656e640a0a66756e6374696f6e206372656174655f7472617028782c79290a6c6f63616c206d203d206372656174655f6d696e6528782c79290a6d2e73746174653d226465746f6e617465220a6372656174655f6669656c6428782d31302c792d31302c322c322c32302c3230290a6372656174655f627562626c657328782c792c31342c31352c322c34290a656e640a0a66756e6374696f")
    (hex 27136 "6e207570646174655f7370696b65792865290a652e76792b3d7465726e61727928652e626f622c302e30312c2d302e3031290a0a69662028742b652e73656564292533303d3d30207468656e20652e626f62203d206e6f7420652e626f6220656e640a0a696620652e73746174653d3d226465746f6e61746522207468656e0a652e616e696d742b3d310a696620652e616e696d743e3d3630207468656e0a6372656174655f6578706c6f73696f6e28652e782c652e792c3135290a6372656174655f627562626c657328652e782c652e792c31302c31352c322c34290a6164645f7368616b652838290a736678283134290a6c6f63616c207064697374203d")
    (hex 27392 "206469737428706c617965722e782c706c617965722e792c652e782c652e79290a69662070646973743c3d333020616e6420706c617965722e737461746520213d2022687572742220616e6420706c617965722e696e76696e63693d3d30207468656e0a687572745f706c6179657228706c61796572290a626f756e63655f72656c617469766528706c617965722c652c392d70646973742f34290a656e640a666f72206f20696e20616c6c286f626a656374732920646f0a6c6f63616c206f64697374203d2064697374286f2e782c6f2e792c652e782c652e79290a6966206f646973743c3d3330207468656e0a6966206f2e6e616d65203d3d20226d696e")
    (hex 27648 "6522206f72206f2e6e616d65203d3d20227370696b657922207468656e0a626f756e63655f72656c6174697665286f2c652c392d6f646973742f34290a6966206f2e6e616d65203d3d226d696e6522207468656e206368616e67655f7374617465286f2c226465746f6e617465222920656e640a656c73650a6b696c6c5f6f626a656374286f290a656e640a656e640a656e640a0a64656c286f626a656374732c65290a656c7365696620652e616e696d743e3d343020616e6420652e616e696d7425323d3d30207468656e0a652e666c617368203d302e310a656c7365696620652e616e696d743e3d3020616e6420652e616e696d742531303d3d30207468")
    (hex 27904 "656e0a652e666c617368203d302e320a656e640a656e640a6170706c795f6672696374696f6e28652c777472667263290a6d6f76652865290a656e640a0a66756e6374696f6e20647261775f7370696b65792865290a647261776f75746c696e6528652e737072692c652e782d342c652e792d342c312c31290a666c6173686f626a65637428652c37290a73707228652e737072692c652e782d342c652e792d342c312c31290a70616c28290a656e640a0a0a66756e6374696f6e206372656174655f636c616d28782c79290a6c6f63616c2065203d6e65775f6f626a65637428782c792c22636c616d222c7570646174655f636c616d2c647261775f636c61")
    (hex 28160 "6d290a652e666c6970783d66616c73650a652e776f623d747275650a652e696e76696e63693d747275650a652e7368616b65736f756e643d66616c73650a0a652e6162735f626f783d66756e6374696f6e28290a0a6c6f63616c20626f78203d206e65775f626f7828652e782d372c652e792d332c652e782b372c652e792b33290a696620652e73746174653d3d226f70656e22207468656e20626f782e79312d3d3420626f782e79322b3d3420656e640a72657475726e20626f780a656e640a616464286f626a656374732c65290a72657475726e20650a656e640a0a66756e6374696f6e207570646174655f636c616d2865290a652e616e696d742b3d31")
    (hex 28416 "0a69662069735f6f666673637265656e28652c363029207468656e2072657475726e20656e640a696620652e73746174653d3d2269646c6522207468656e0a652e666c6970783d7465726e61727928706c617965722e783e652e782c747275652c66616c7365290a696620652e616e696d74203e3d3630207468656e0a6966206e6f7420652e7368616b65736f756e6420616e64206e6f742069735f6f666673637265656e286529207468656e207366782831352920652e7368616b65736f756e643d7472756520656e640a6966207425323d3d30207468656e0a696620652e776f62207468656e0a652e782b3d320a656c73650a652e782d3d320a656e640a")
    (hex 28672 "652e776f623d6e6f7420652e776f620a656e640a656e640a696620652e616e696d74203e3d3830207468656e0a6368616e67655f737461746528652c226f70656e22290a652e7368616b65736f756e643d66616c73650a652e696e76696e63693d66616c73650a656e640a656e640a0a696620652e73746174653d3d226f70656e22207468656e0a696620652e616e696d743d3d31207468656e0a6c6f63616c207678203d2028706c617965722e782d652e78292f6469737428706c617965722e782c706c617965722e792c652e782c652e79290a6c6f63616c207679203d2028706c617965722e792d652e79292f6469737428706c617965722e782c706c61")
    (hex 28928 "7965722e792c652e782c652e79290a6372656174655f627562626c657328652e782c652e792d332c726e642833292b322c342c312c33290a6372656174655f706561726c28652e782c652e792d322c76782a322c76792a312e36290a736678283136290a656e640a696620652e616e696d743e3d313230207468656e0a6368616e67655f737461746528652c2269646c6522290a652e696e76696e63693d747275650a656e640a656e640a656e640a0a66756e6374696f6e20647261775f636c616d2865290a6c6f63616c20737072692c796f66662c683d32392c2d372c310a0a696620652e73746174653d3d226f70656e22207468656e0a737072692c796f")
    (hex 29184 "66662c683d382c2d31352c320a656e640a647261776f75746c696e6528737072692c652e782d382c652e792b796f66662c322c682c652e666c6970782c66616c73652c302c74727565290a656e640a0a66756e6374696f6e206372656174655f706561726c28782c792c76782c7679290a6c6f63616c20653d6e65775f6f626a65637428782c792c22706561726c222c7570646174655f706561726c2c647261775f706561726c290a652e76783d76780a652e76793d76790a0a652e6162735f626f783d66756e6374696f6e28290a72657475726e206e65775f626f7828652e782d322c652e792d322c652e782b322c652e792b32290a656e640a0a61646428")
    (hex 29440 "6f626a656374732c65290a72657475726e20650a656e640a0a66756e6374696f6e207570646174655f706561726c2865290a696620652e783c2d3230206f7220652e783e726f6f6d636f6c732a313430206f7220652e793c2d3230206f7220652e793e726f6f6d726f77732a313430207468656e0a64656c286f626a656374732c65290a656e640a6d6f76652865290a656e640a0a66756e6374696f6e20647261775f706561726c2865290a647261776f75746c696e652832362c652e782d322c652e792d322c312c312c66616c73652c66616c73652c302c74727565290a656e640a0a66756e6374696f6e206372656174655f6578697428782c79290a6c6f")
    (hex 29696 "63616c20653d7b0a783d782c0a793d792c0a6e616d653d2765786974272c0a73746174653d276f70656e272c0a636f6d6261743d66616c73652c0a6162735f626f783d6e65775f626f7828782d342c792d342c782b342c792b34290a7d0a65786974203d20650a72657475726e20650a656e640a0a66756e6374696f6e207570646174655f6578697428290a696620657869742e636f6d6261743d3d7472756520616e6420657869742e73746174653d3d22636c6f73656422207468656e0a6c6f63616c206e6f203d20300a666f72206920696e20616c6c286f626a656374732920646f0a696620692e6e616d653d3d226d696e6522206f7220692e6e616d65")
    (hex 29952 "3d3d227370696b657922206f7220692e6e616d653d3d22706561726c22207468656e0a6e6f2b3d310a656e640a656e640a696620236f626a656374732d6e6f203c3d2030207468656e0a657869742e73746174653d226f70656e220a6d757369632835290a6372656174655f627562626c657328657869742e782c657869742e792c31302c362c322c34290a656e640a656e640a696620742536303d3d30207468656e206372656174655f627562626c657328657869742e782c657869742e792c726e642831292b312c322c312c322920656e640a656e640a0a66756e6374696f6e20636f6c6c5f6578697428290a696620636f6c6c28657869742e6162735f")
    (hex 30208 "626f782c706c617965722e6162735f626f78282929207468656e0a696620657869742e73746174653d3d226f70656e2220616e6420706c617965722e7374617465213d226465616422207468656e0a736678283239290a6e6578745f726f6f6d28290a656e640a656e640a656e640a0a66756e6374696f6e20647261775f6578697428290a6c6f63616c2063612c63623d302c300a696620657869742e73746174653d3d22636c6f73656422207468656e2063612c63623d2031332c3220656e640a70616c28382c30290a70616c28392c6361290a70616c2831302c6362290a737072283130382c657869742e782d382c657869742e792d382c322c32290a70")
    (hex 30464 "616c28290a656e640a0a66756e6374696f6e206372656174655f696e6b2878312c79312c78322c79322c7570726174652c626f7468290a65203d207b0a626f783d6e65775f626f782878312c79312c78322c7932292c0a7570726174653d757072617465206f7220302c0a626f74683d626f7468206f722066616c73652c0a6e616d653d22696e6b222c0a7570646174653d7570646174655f696e6b2c0a636f6c6c3d636f6c6c5f696e6b2c0a647261773d647261775f696e6b0a7d0a652e7570726174652a3d302e310a6164642868617a617264732c65290a72657475726e20650a656e640a0a66756e6374696f6e207570646174655f696e6b2865290a6c")
    (hex 30720 "6f63616c20626f783d652e626f780a626f782e79312d3d652e7570726174650a696620652e626f7468207468656e20626f782e79322d3d652e75707261746520656e640a696620626f782e79323c30207468656e2064656c2868617a617264732c652920656e640a0a6c6f63616c2063626f78203d6e65775f626f782863616d782d32302c63616d792d32302c63616d782b3134382c63616d792b313438290a0a696620636f6c6c28626f782c63626f7829207468656e0a6966207425333d3d30207468656e0a6c6f63616c2078312c79312c78322c79323d626f782e78312c626f782e79312c626f782e78322c626f782e79320a6c6f63616c2074626c656e")
    (hex 30976 "2c726c6c656e2c6f6666203d2078322d78312c79322d79312c31300a666f7220693d312c20666c72282874626c656e2b3634292f36342920646f0a6372656174655f7061727469636c6528666c7228726e642874626c656e292b7831292c79312b6f66662c302c28726e6428302e32292b302e322b652e757072617465292a2d31290a6372656174655f7061727469636c6528666c7228726e642874626c656e292b7831292c79322d6f66662c302c726e6428302e32292b302e322d28652e7570726174652a302e3929290a656e640a666f7220693d312c20666c722828726c6c656e2b3634292f36342920646f0a6372656174655f7061727469636c652878")
    (hex 31232 "322d6f66662c666c7228726e6428726c6c656e292b7931292c726e6428302e32292b302e322c30290a6372656174655f7061727469636c652878312b6f66662c666c7228726e6428726c6c656e292b7931292c28726e6428302e32292b302e32292a2d312c30290a656e640a656e640a656e640a656e640a0a66756e6374696f6e20636f6c6c5f696e6b2865290a6c6f63616c20626f78203d20652e626f780a6c6f63616c207073203d20706c617965722e73746174650a696620636f6c6c28626f782c706c617965722e6162735f626f7828292920616e64207073213d2261747461636b2220616e64207073213d22687572742220616e64207073213d2264")
    (hex 31488 "65616422207468656e0a6c6f63616c2063656e747265203d207b7d0a63656e7472652e78203d20626f782e78312b626f782e78322f320a63656e7472652e79203d20626f782e79312b626f782e79322f320a687572745f706c6179657228706c61796572290a626f756e63655f72656c617469766528706c617965722c63656e7472652c32290a656e640a656e640a0a66756e6374696f6e20647261775f696e6b2865290a6c6f63616c2062203d20652e626f780a70616c7428302c66616c7365290a7265637466696c6c28622e78312c622e79312c622e78322c622e79322c30290a70616c28290a656e640a0a0a66756e6374696f6e207570646174655f62")
    (hex 31744 "6f737328290a626f73732e616e696d742b3d310a696620626f73732e776176653e30207468656e20626f73732e776176652d3d3120706c617965722e76792d3d302e34206164645f7368616b65283129656e640a696620626f73732e73746174653d3d2261637469766522207468656e0a696620636f6c6c28706c617965722e6162735f626f7828292c626f73732e626f7829207468656e0a696620706c617965722e73746174653d3d2261747461636b22207468656e0a63616e63656c5f61747461636b28290a736678283231290a626f73732e68702d3d310a6164645f7368616b652834290a696620626f73732e68703c3d30207468656e0a7366782832")
    (hex 32000 "32290a6368616e67655f737461746528626f73732c226479696e6722290a666f72206920696e20616c6c286f626a656374732920646f0a6b696c6c5f6f626a6563742869290a656e640a656e640a656e640a626f756e63655f72656c617469766528706c617965722c626f73732c32290a656e640a69662074253135303d3d30207468656e0a6372656174655f627562626c6573286172672236342c3634302c32302c34302c322c332c22290a6372656174655f696e6b28617267222d32302c3634302c3134362c3636302c31332c747275652c22290a626f73732e776176653d34300a6d757369632833290a656e640a656c7365696620626f73732e737461")
    (hex 32256 "74653d3d226479696e6722207468656e0a6966207425323d3d30207468656e0a6372656174655f6578706c6f73696f6e28726e64283830292b32302c726e6428313238292b3531322c726e642838292b38290a656e640a6966207425666c7228726e64283130292b34293d3d30207468656e2073667828313429206164645f7368616b6528342920656e640a696620626f73732e616e696d743e3d31353020616e6420706c617965722e7374617465213d2264656164227468656e206368616e67655f737461746528626f73732c22646561642229206e6578745f726f6f6d282920656e640a656e640a656e640a0a66756e6374696f6e20647261775f626f73")
    (hex 32512 "7328290a647261776f75746c696e65286172672236392c34382c3537362c342c342c66616c73652c66616c73652c302c747275652c22290a696620626f73732e68703c33207468656e0a737072286172672237332c36392c3539362c22290a696620626f73732e68703c32207468656e0a737072286172672237332c35322c3539362c312c312c66616c73652c747275652c22290a737072286172672237332c36362c3538302c312c312c747275652c22290a696620626f73732e68703c31207468656e0a737072286172672237332c35362c3538312c312c312c747275652c747275652c22290a737072286172672237332c36322c3538382c312c312c2229")
    (hex 32768 "0a656e640a656e640a656e640a656e640a0a2d2d3e380a2d2d6f626a656374207574696c730a0a66756e6374696f6e20737061776e6c697374286c290a6c6f63616c206f6c203d207061727365286c290a666f7220693d312c236f6c2c3320646f0a6c6f63616c20742c782c793d6f6c5b695d2c6f6c5b692b315d2c6f6c5b692b325d0a737061776e7479706528742c782c79290a656e640a656e640a0a66756e6374696f6e20737061776e7479706528747970652c782c79290a696620747970653d3d33207468656e0a6372656174655f736e617070657228782c79290a656c7365696620747970653d3d34207468656e0a6372656174655f707566666572")
    (hex 33024 "28782c79290a656c7365696620747970653d3d35207468656e0a6372656174655f737175696428782c79290a656c7365696620747970653d3d31207468656e0a6372656174655f7370696b657928782c79290a656c7365696620747970653d3d32207468656e0a6372656174655f6d696e6528782c79290a656c7365696620747970653d3d30207468656e0a6372656174655f6578697428782c79290a656c7365696620747970653d3d36207468656e0a6372656174655f636c616d28782c79290a656c7365696620747970653d3d37207468656e0a6372656174655f7363686f6f6c28782c79290a656c7365696620747970653d3d38207468656e0a637265")
    (hex 33280 "6174655f736861726b28782c79290a656e640a656e640a0a66756e6374696f6e20636f6c6c28612c62290a72657475726e206e6f742028612e78313e622e7832206f7220612e79313e622e7932206f7220612e78323c622e7831206f7220612e79323c622e7931290a656e640a0a66756e6374696f6e206d6f7665286f290a6f2e782b3d6f2e76780a6f2e792b3d6f2e76790a656e640a0a66756e6374696f6e206b696c6c5f6f626a6563742865290a6164645f7368616b652835290a6372656174655f6578706c6f73696f6e28652e782c652e792c35290a6372656174655f627562626c657328652e782c652e792c726e642832292b322c342c312c33290a")
    (hex 33536 "666f7220693d312c666c7228726e642834292b332920646f0a6372656174655f7061727469636c6528652e782c652e792c726e642833292b2d322c726e642833292b2d322c74727565290a656e640a7366782837290a64656c286f626a656374732c65290a667265657a653d320a656e640a0a0a66756e6374696f6e206170706c795f6672696374696f6e286f2c66726963290a6f2e76782a3d667269630a6f2e76792a3d667269630a656e640a0a66756e6374696f6e20626f756e6365286f2c62782c6279290a6966206278207468656e206f2e7678203d20627820656e640a6966206279207468656e206f2e7679203d20627920656e640a656e640a0a66")
    (hex 33792 "756e6374696f6e20626f756e63655f72656c617469766528702c6f2c737472290a6c6f63616c207264697374203d206469737428702e782c702e792c6f2e782c6f2e79290a6c6f63616c20626f756e636578203d2028702e782d6f2e78292f72646973740a6c6f63616c20626f756e636579203d2028702e792d6f2e79292f72646973740a626f756e6365782a3d7374720a626f756e6365792a3d7374720a626f756e636528702c626f756e6365782c626f756e636579290a656e640a0a66756e6374696f6e206368616e67655f7374617465286f2c7374617465290a6966206f2e737461746520213d207374617465207468656e0a6f2e7374617465203d20")
    (hex 34048 "73746174650a6f2e616e696d74203d20300a656e640a656e640a0a66756e6374696f6e206170706c795f616363656c286f2c7470737064290a6c6f63616c206c3d64697374286f2e76782c6f2e7679290a6c6f63616c20726c3d6d696e286c2c7470737064290a6f2e76783d6f2e76782f6c2a726c0a6f2e76793d6f2e76792f6c2a726c0a656e640a0a66756e6374696f6e206973736f6c696428782c2079290a6c6f63616c2074696c652c636f6c2c726f77203d2067657474696c6528782c79290a69662074696c65207468656e0a6f78203d2028782d28636f6c2a31323829292f380a6f79203d2028792d28726f772a31323829292f380a6f6666736574")
    (hex 34304 "78203d202874696c652538292a31360a6f666673657479203d20666c722874696c652f38292a31360a76616c3d6d676574286f782b6f6666736574782c206f792b6f666673657479290a72657475726e20666765742876616c2c2031290a656e640a656e640a0a66756e6374696f6e2064657465637477616c6c73286f290a6c6f63616c206862203d206f2e6162735f626f7828290a6c6f63616c2078312c78322c79312c79322c78632c79633d68622e78312c68622e78322c68622e79312c68622e79322c302c300a6c6f63616c2061646a757374203d20302e310a0a666f7220693d79312c793220646f0a69662078312d313c30206f72206973736f6c69")
    (hex 34560 "642878312d312c6929207468656e0a6f2e782b3d61646a7573740a78632b3d310a656e640a69662078322b313e636d617878206f72206973736f6c69642878322b312c6929207468656e0a6f2e782d3d61646a7573740a78632b3d310a656e640a656e640a0a666f7220693d78312c783220646f0a69662079312d313c30206f72206973736f6c696428692c79312d3129207468656e0a6f2e792b3d61646a7573740a79632b3d310a656e640a69662079322b313e636d617879206f72206973736f6c696428692c79322b3129207468656e0a6f2e792d3d61646a7573740a79632b3d310a656e640a656e640a0a69662078633e3020616e642078633e3d7963")
    (hex 34816 "207468656e20626f756e6365286f2c6f2e76782a2d302e382c6e696c2920656e640a69662079633e3020616e642079633e3d7863207468656e20626f756e6365286f2c6e696c2c6f2e76792a2d302e382920656e640a0a6966202878633e30206f722079633e302920616e64206f2e6e616d653d3d22706c617965722220616e64206f2e73746174653d3d2261747461636b22207468656e0a69662028706c617965722e6469723d3d32206f7220706c617965722e6469723d3d362920616e642079633e7863207468656e0a656c73650a63616e63656c5f61747461636b28290a656e640a656e640a656e640a0a66756e6374696f6e20736574646972656374")
    (hex 35072 "696f6e286f2c626c2c62722c62752c6264290a696620627520616e64206e6f7428626c206f72206272206f7220626429207468656e206f2e646972203d203020656e640a696620627220616e64206e6f74286275206f7220626c206f7220626429207468656e206f2e646972203d203220656e640a696620626420616e64206e6f7428626c206f72206275206f7220627229207468656e206f2e646972203d203420656e640a696620626c20616e64206e6f74286264206f72206272206f7220627529207468656e206f2e646972203d203620656e640a69662028627520616e642062722920616e64206e6f7428626c206f7220626429207468656e206f2e64")
    (hex 35328 "6972203d203120656e640a69662028627220616e642062642920616e64206e6f7428626c206f7220627529207468656e206f2e646972203d203320656e640a69662028626420616e6420626c2920616e64206e6f74286272206f7220627529207468656e206f2e646972203d203520656e640a69662028626c20616e642062752920616e64206e6f74286272206f7220626429207468656e206f2e646972203d203720656e640a656e640a0a66756e6374696f6e206164645f7368616b652870290a6c6f63616c20613d726e642831290a73686b782b3d702a636f732861290a73686b792b3d702a73696e2861290a656e640a0a66756e6374696f6e2069735f")
    (hex 35584 "6f666673637265656e286f2c627566666572290a6c6f63616c20627566203d20627566666572206f7220300a0a6966206f2e783c63616d782d627566206f72206f2e783e63616d782b3132372b627566206f72206f2e793c63616d792d627566206f72206f2e793e63616d792b3132372b627566207468656e2072657475726e207472756520656e640a656e640a0a2d2d3e380a2d2d656666656374732d2d0a0a0a66756e6374696f6e206372656174655f6578706c6f73696f6e28782c792c72290a6c6f63616c20653d7b0a783d782c0a793d792c0a723d722c0a703d302c0a647261773d647261775f6578706c6f73696f6e2c0a7d0a6164642866782c65")
    (hex 35840 "290a656e640a0a66756e6374696f6e20647261775f6578706c6f73696f6e2873290a696620732e703c32207468656e0a6369726366696c6c28732e782c732e792c732e722c30290a656c7365696620732e703c34207468656e0a6369726366696c6c28732e782c732e792c732e722c37290a0a696620732e703c3320616e6420732e723e34207468656e0a666f7220693d302c3220646f0a6c6f63616c20783d732e782b726e6428322e322a732e72292d312e312a732e720a6c6f63616c20793d732e792b726e6428322e322a732e72292d312e312a732e720a6c6f63616c20723d302e32352a732e722b726e6428302e352a732e72290a6372656174655f65")
    (hex 36096 "78706c6f73696f6e28782c792c72290a656e640a656e640a656c7365696620732e703c35207468656e0a6369726328732e782c732e792c732e722c37290a0a64656c2866782c73290a72657475726e0a656e640a0a732e702b3d310a656e640a0a66756e6374696f6e206372656174655f627562626c657328782c792c6e756d2c7370726561642c6d696e73697a652c6d617873697a65290a666f7220693d312c6e756d20646f0a6c6f63616c20613d726e642831290a6c6f63616c20623d7b0a783d782b7370726561642a636f732861292c0a793d792b7370726561642a73696e2861292c0a723d726e64286d617873697a652d6d696e73697a65292b6d69")
    (hex 36352 "6e73697a652c0a647261773d647261775f627562626c650a7d0a6164642866782c62290a656e640a656e640a0a66756e6374696f6e20647261775f627562626c652862290a6369726328622e782b302e352c622e792b302e352c622e722c3133290a6369726366696c6c28622e782b302e352d622e722a302e342c622e792b302e352d622e722a302e342c622e722a302e322c36290a622e792d3d622e722a302e360a696628622e793c30297468656e2064656c2866782c622920656e640a656e640a0a66756e6374696f6e206372656174655f6665726e28782c792c6c656e2c636f6c290a663d7b783d782c793d792c6c656e3d6c656e2c636f6c3d636f6c")
    (hex 36608 "2c666c6970783d66616c73652c647261773d647261775f6665726e7d0a662e6275623d666c7228726e642831303830292b373230290a6164642866782c66290a656e640a0a66756e6374696f6e20647261775f6665726e2866290a696620742535303d3d30207468656e20662e666c6970783d6e6f7420662e666c69707820656e640a696620666c7228742b313038302925662e6275623d3d30207468656e206372656174655f627562626c657328662e782b332c662e792c312c312c312c322920656e640a70616c28382c662e636f6c290a666f7220693d312c662e6c656e20646f0a696620693d3d662e6c656e207468656e0a737072283130352c662e78")
    (hex 36864 "2c662e792d692a382c312c312c662e666c697078290a656c73650a737072283132312c662e782c662e792d692a382c312c312c662e666c697078290a656e640a656e640a70616c28290a656e640a0a0a66756e6374696f6e20666c6173686f626a656374286f2c63290a6966206f2e666c617368203e2030207468656e0a6f2e666c6173682d3d302e310a666f7220693d302c313520646f0a70616c28692c63290a656e640a656c73650a6f2e666c617368203d20300a656e640a656e640a0a66756e6374696f6e20647261776f75746c696e65286e2c782c792c772c682c666c69705f782c666c69705f792c632c6d61696e290a666f7220693d312c313520")
    (hex 37120 "646f0a70616c28692c63290a656e640a0a666f722078783d2d312c3120646f0a666f722079793d2d312c3120646f0a737072286e2c782b78782c792b79792c772c682c666c69705f782c666c69705f79290a656e640a656e640a70616c28290a6966206d61696e207468656e20737072286e2c782c792c772c682c666c69705f782c666c69705f792920656e640a656e640a0a66756e6374696f6e20626f6c647072696e74287374722c782c792c636f6c290a633d636f6c206f7220370a666f722078783d2d312c3120646f0a666f722079793d2d312c3120646f0a7072696e74287374722c782b78782c792b79792c30290a656e640a656e640a7072696e74")
    (hex 37376 "287374722c782c792c63290a656e640a0a66756e6374696f6e206372656174655f7061727469636c6528782c792c76782c76792c7070290a70203d207b0a783d782c0a793d792c0a76783d76782c0a76793d76792c0a636f6c733d7b302c302c327d2c0a73697a653d31302c0a6167653d302c0a6d61786167653d33300a7d0a6966207070207468656e0a702e73697a653d310a702e6d61786167653d31350a702e636f6c733d7b372c372c372c362c362c31327d0a702e70703d747275650a656e640a616464287061727469636c65732c70290a656e640a0a66756e6374696f6e207570646174655f7061727469636c657328290a666f72207020696e2061")
    (hex 37632 "6c6c287061727469636c65732920646f0a702e6167652b3d310a696620702e6167653d3d702e6d6178616765206f722069735f6f666673637265656e28702c333029207468656e2064656c287061727469636c65732c702920656e640a6c6f63616c206369203d20312b666c722828702e6167652f702e6d6178616765292a23702e636f6c73290a702e636f6c203d20702e636f6c735b63695d0a696620702e6167652f702e6d6178616765203e20302e36207468656e20702e66696c6c203d2066616465735b345d20656e640a696620702e6167652f702e6d6178616765203e20302e38207468656e0a702e66696c6c203d2066616465735b325d0a696620")
    (hex 37888 "6e6f7420702e7070207468656e0a702e73697a653d31340a656e640a656e640a0a6d6f76652870290a656e640a656e640a0a66756e6374696f6e20647261775f7061727469636c657328290a666f72207020696e20616c6c287061727469636c65732920646f0a696620702e66696c6c207468656e2066696c6c7028702e66696c6c2920656e640a6369726366696c6c28702e782c702e792c702e73697a652c702e636f6c290a66696c6c7028290a656e640a656e640a0a2d2d3e380a2d2d7574696c69746965732d2d0a0a66756e6374696f6e20706172736528737472696e67290a6c6f63616c2064617461203d207b7d0a6c6f63616c2064203d2022220a")
    (hex 38144 "666f7220693d312c23737472696e6720646f0a6c6f63616c2073203d2073756228737472696e672c692c69290a6966207320213d20222c22207468656e0a643d642e2e730a656c73650a696620643d3d227472756522207468656e0a643d747275650a656c7365696620643d3d2266616c736522207468656e0a643d66616c73650a656c73650a643d666c722864290a656e640a61646428646174612c64290a643d22220a656e640a656e640a72657475726e20646174610a656e640a0a66756e6374696f6e2061726728737472290a72657475726e20756e7061636b2870617273652873747229290a656e640a0a66756e6374696f6e20756e7061636b2874")
    (hex 38400 "2c69290a693d69206f7220310a696620745b695d213d6e696c207468656e0a72657475726e20745b695d2c756e7061636b28742c692b31290a656e640a656e640a0a66756e6374696f6e207465726e61727928632c612c62290a69662063207468656e2072657475726e206120656c73652072657475726e206220656e640a656e640a0a66756e6374696f6e2067657474696c6528782c79290a6c6f63616c20636f6c203d20666c7228782f313238290a6c6f63616c20726f77203d20666c7228792f313238290a6c6f63616c2074696c65203d20726f6f6d74696c65735b28726f6f6d636f6c732a726f77292b726f772b636f6c2b315d0a72657475726e20")
    (hex 38656 "74696c652c636f6c2c20726f770a656e640a0a66756e6374696f6e20646973742878612c79612c78622c7962290a6966207862207468656e2078613d78622d78612079613d79622d796120656e640a6c6f63616c2064203d206d617828616273287861292c61627328796129290a6c6f63616c206e203d206d696e28616273287861292c6162732879612929202f20640a72657475726e2073717274286e2a6e202b31292a640a656e640a0a66756e6374696f6e206e65775f626f782878312c79312c78322c7932290a72657475726e207b78313d78312c79313d79312c78323d78322c79323d79327d0a656e640a0a66756e6374696f6e2074696d65722829")
    (hex 38912 "0a6c6f63616c206d696e2c7365633d676d2c666c722867742f3330290a6966206d696e3c3130207468656e0a6d696e3d2230222e2e6d696e0a656e640a6966207365633c3130207468656e0a7365633d2230222e2e7365630a656e640a72657475726e206d696e2e2e223a222e2e7365630a656e640a0a5f5f6766785f5f0a30303030303030303030383865303030303038386530303030303030303865383030303030386538303030653030303030303065303030303030306330303030303030303030303030303031643030303030323232323030303030303030303030303030303030303030303030303637373737373030303030303036303030300a")
    (hex 39168 "30303030303030303030313738653030303031373865303030303038373138383030303837313838653030386530303030303038653030303030306330303030303030303030303030303164643530303032653232323230303030303030303030303030373637303064363636363636363636363737303030303637363030300a30303730303730303030373738386530303037373838653030653838373738323065383837373832383838323837316565383832383731653030306330303030303030303030303030303164643530303265323664323232303030303030303030373737373736303030646464646464363636363637363030373737373730")
    (hex 39424 "300a30303037373030303032383838383830303238383838383030303832383838323030383838383832323838383837373838383838383737383030636336303030303030303030303030303164356464303232366538643232303030303030303037363636373737303030303030303030303030363737373630373637363730300a3030303737303030323838383832323032383238323832306565383838383230303038383238323038383838383838323238383838383832306337313630303030303030303030303030316464356430323264383835323130303030303037373636363636373030303064646464646436363636363736303736363636")
    (hex 39680 "3637300a30303730303730303030383832323030303038383232303038383238383230303038383838323230303032323838323038303238383232303063373763363030303030303030303030303164646464643232326435323131303030303037363636643036363730303064363636363636363636363737303037363630363637300a303030303030303030303838383030303030383838303030303832383230303030323838323030303030303232323030303030323232303030636363633630303030303030303030303030316464356430323232323131303030303030363636643064363637303030303030303036373737373730303030373636")
    (hex 39936 "30363637300a30303030303030303038383238303030303038383238303030303830303030303030323830303030303030303030303030303030303030306463636363633630303030303030303030303031646464353030313131313030303030303636366430643636373030303030303030303030303030303030303037363630363637300a30303030303030363630303030303030303036303030303636303030303030303030303030303036363030303030303036303030303030366430636363633030303030303030303030303031646435643066373730303030303030363664643064363637303030303030303030303030303030303030303037")
    (hex 40192 "366430643637300a36363030303030306363363630303030303063363030303063633636303030303030303030303030636336363030303030363065323036303030636363303030303030303030666665653030316464646637373736303030303030366430306436363637303030303030303030303064643535353030303036366430643636300a3063363036366363633737636330303030633663363636636337376363303030303030303636636363373763633030303030363232363030303064636330303030303032656665656565653231316435373737373630303030306464303030643636373030303030303064356464353535646464356430")
    (hex 40448 "3030366430643630300a30636363636363636337316363636363636363636363636363373163636363633636366363636363633731636363636330653232323232303030646463303030643132323232656565653232323164303737373664303030303064303030643636303030303030306431316435646464646464646431643030366430643630300a306363306464646363636363633030303030303064646463636363636330303030636330646464636363636363303030303232323231313030303063303030306464643131313131313131313131643030363664303030303030303030643636303030303030303064646431313131313131313131")
    (hex 40704 "64643030366430643630300a64643030303030646463633030303030303030303030306464636330303030306464643030303064646363303030303030306432316430303030636336303030303064646464646464646464646430303030303030303030303030306464303030303030303030303030646464646464646464646464303030366430643630300a30303030303030306430303030303030303030303030303064303030303030303064303030303030643030303030303030643031313064303063646464363030303030303064356435643564353030303030303030303030303030303030303030303030303030303030303030643564356435")
    (hex 40960 "643530303030643030306430300a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303064303030303030643064303030633030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030306330303030303030633030303030303036303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 41216 "3030303030303030303030303030300a30303030303030303030303030306330303030303030303030303030303063303030303030303030303030303030633030303063303030303030306330303030303030303630303030303030303030303030363030303630303030303030303030303030303030303030303030303030303030303030303030303030303063300a303030303030303030303030306330303030303030303030303030303063303030303030303030303030303030633030303030633030303030303063303030303030306363303030303030303030303030306363306336303030303030303030303636363030303030303030303030")
    (hex 41472 "30303030303030303030363030306330300a30303030303030303030303063303030303030303030303030303030633030303030303030303030303030306330303030306363363030303030636336303030633063636330303036303030303030303030306463633030363030303030303030306363633030303630303030303030303030303030303636636363633030300a30303030303030366363636330303030303030303030303663636363303030303030303030303036636363633030303030633731363030303063373136303030306464646336363030363030303030303030303063633630303630303030303030303063633636303036303030")
    (hex 41728 "303030303030303030366331376363303030300a30303030303036636337316330303030303030303030366363373163303030303030303030303663633731633030303030633737633630303063373763363030303030306463636363633030303030303030303064636363636330303030303030306364646363636363303030303030303630303663636337376363303030300a3030303036636363633737633030303030303030366363636337376330303030303030303663636363373763303030303063636363363030306363636336303030303030306363636363363030303030303030303063636363633630303030303064643030636363636336")
    (hex 41984 "3030303030306336306363636363636330303030300a30303036306363636363636430303030303030363063636363636364303030303030303630636363636363643030303064636363636336306463636363633630303030303064636463636336303030303030303030646364636363363030303030303030306463646363633630303030306463366363636363643030303030300a303030303063636463636430303030303030303030636364636364303030303030303030306363646363643030303030643063636363303064306363636330303030303030306463636363633030303030303030303064636363636330303030303030303030646363")
    (hex 42240 "63636330303030303064636464646464303030303030300a30303030636363636364303030303030303030306363636363643030303030303036363063636363636430303030303030306363633030303030636363303030303030303030646363373763303030303030303030306463633737633030303030303030303064636337376330303030303064636363643030303030303030300a30303030366464643030303030303030303030303664646430303030303030303030633663646464303030303030303030306463633030303030646363303030303030303030306463373163303030303030303030303064633731633030303030303030303030")
    (hex 42496 "646337316330303030303063636363303030303030303630300a30363663636430303030303030303030303030366364303030303030303030303030306363643030303030303030303030306464633030303030646463303030303030303030303064636363303030303030303030303030646363633030303030303030303030306463636330303030303030646363633636303030636330300a3630636363303030303030303030303030303663633030303030303030303030303063636430303030303030303030303030306330303030303030633030303030303030303030303030303063303030303030303030303030303030633030303030303030")
    (hex 42752 "3030303030303063303030303030306463636363363663633030300a30303063643030303030303030303030303064646430303030303030303030303064643030303030303030303030303030306363303030303030306363303030303030303030303030303030306330303030303030303030303030303063303030303030303030303030303030633030303030303064646363636363303030300a303030306430303030303030303030303064303030643030303030303030303030303030303030303030303030303030636364643030303030303064636336303030303030303030303030303030633030303030303030303030303030306330303030")
    (hex 43008 "30303030303030303030306330303030303030306464646463303030300a30303064303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303063303030303030306464303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303064303030300a66666666666666663033333333333333333333333333333333333333333333303333333333333333303030303030303030303030363636363636363630303030303030303030303030303030373030303939303030303939303030303030303030")
    (hex 43264 "303066343030303030306634303030303030303030303430303030303030300a66666638666666383333353335333335353335333335333535333533353333333333353533333333303030303030303030363636303030303030303036363630303030303030303030303030373030303039393030303039393030303030303030303066343030303030303434303030303030343030663466663034303030300a6666663838663865333565356533356565356535336535653335653532353533333565653533353530303030303030363630303030303030303030303030303636303030303030303030303030373030303039393939393939393937373030")
    (hex 43520 "3030303034343030303030306634303030303030303466666634663466303030300a66666638383865663565666666356566666566653566656635656632653232333565666665356565303030303030366430303030373737373030303030303030303630303030303030303030373030303030393939393939393939373139393930303439393430303030663934343030303030346666666634666666663030300a383838383838386665666666666666666666666665666666656666656565653565666666666566663030303030366430303037373737373730303030303030303064363030303030303037373030303030303966663939393939393939")
    (hex 43776 "39393930306639393430303030663934343030303434666666666666666666666630300a65653838383838386666666666666666666666666666666666666665656565326666666666666666303030303664643037373737303030303030303030303030303064363030303037373030373030303039393030666666663939666666393030306639393430303030663439343030303066666637376666666666373130300a66666665386565656666666666666666666666666666666666666665656565656666666666666666303030363564643737373730303030303030303030303030303064643630303030303030303730303939303030306666663939")
    (hex 44032 "666666303030306639343430303030343939343030306666666631376666666666373766300a66666666386666666666666666666666666666666666666666666665656565656666666666666666303036353035373737303030303030303030303030303030306464353536303030303030303030303030303030303030393930303030303030663934393934303034663939343430306634346666666666666666666666300a6666663333666666656565656565656564646435353535356565653232323232666634343434666630303630303737376430303030303030303030303030303064643530303630303161316131613161303930303030393930")
    (hex 44288 "3030303030303030663439393934303066393939343430303466666666666666666666666634340a66666633316666666565656565656565643131313131313265656532323232326634396666393466303630303737373564643030303030303030303030303064643530303030363061316131613161313030393030303039393030303030303030343939393934303066393934393430303434666666663466666666346666300a666633333333666666666666666666666464643535353532666666656565656534666534346665343036303037373030356464303030303030303030303064643530303030303630316131613161316130303939393939")
    (hex 44544 "39393939373730303034343439393434346634343439393434303034666666346666666666663430300a66336233333331666565656565656565353131313131313265656532323232323439343966343934303630303737303030356464646430303232303030646435303030303030363061316131613161313030393939393939393939373139393966373739343737346637373939373734303034343466666666346666666634300a66333333333131666565656565656565356464353535353265656532323232323466346634666534363030373730303030306464323232323232326464643530303030303030303631613161316131613030396666")
    (hex 44800 "393939393939393939393966373134343137346637313434313734303030343434666666663466663030300a65333333333131666565656565656565353131313131313265656532323232323439343965393465363030373730303030303532323532323232323264643030303030303030303661316131613161313030393030666666393966666666393030343838383834303034383838383430303030303434343434666634303030300a6665333131316565656565656565656535646435353535326565653232323232346665343434656636303037373030303030323232323232323232323235303030303030303030363161316131613161303930")
    (hex 45056 "3030306666393966666666303030303830383830303038303830383030303030303030343434343030303030300a66666565656565656666666666666666353232323232323266666665656565656634346565656666363030373730303030323232323232323232323232323030303030303030303661316131613161313030303030303039393030303030303030383038303038303038303038303830303030303030303030303030303030300a666666666666666666666666666666666666666666666666666666656565656566666666666666663630303030303030303232323232323232323232323130303030303030303036303030303030303031")
    (hex 45312 "31313131313161313131313131313130303030303064646464303030303030303030303466303030303030346630300a66666666666666666666666666666666666666666666666666666665656565656666666666666666363030303030303030323232383832323232383832313030303030323030303630303038383030303131313131316131613131313131313130303030646435353535353530303030303030666666343030303066666634300a66666639666666666666666666666666666666666666666666666665656565656666666666666666363030303030303030303232323838323238383231313030303032303030353630303838383830")
    (hex 45568 "303131313131613161316131313131313130303064353535323235353535303030663066313766313730306631376631370a66666666666666666666666666666666666666666666666666666665656565656666666666666666363030303030303030323132323232323232323131323030323231303030353630303834383830303131313161316131613161313131313130306435353232396132323535353030346666373766373766666637376637370a6666666666666666656666666666666666666666666666666666666565656532666666666666396630363030303032323231303031323232323131313132323232303030303036303030383438")
    (hex 45824 "3830303131316131613161316131613131313130643535326138396138393235353530666666666666666634666666666666660a66666666666666663265666666666666666666666666666666666665656532326639666666666666303630303032313030303030303664646435313030303130303030303035363030383438383030303131613161316131613161316131313130643532396138396138396132353530303034346666663466303466666666340a666666666666666630326565656565656565656565656565656565656532323066666666666666663036303030323030303030303036646464353030303030303030303035353630303834")
    (hex 46080 "38383030303161316131613161316131613161313164353532396138396138396132353532303030666666343030303066346634300a66666666666666663030323232323232323232323232323232323232323230306666666666666666303036303230303030303030303038653238303030303030303030303536303030303834383830306131613161316131613161316131613164353238396138396138396138643532303030303434303030303030343430300a35643535353532326666666666666666666666656565656566666666666666666666666565656565303036303030303030303030303830653238303030303030303030353536303030")
    (hex 46336 "303834383830303161316131613161316131613161316164353238396138396138396138643532353535353535353535643535353532320a35643535353532326565656565656565656565323232323266666666666666666666666565656565303030363030303030303030306538323030383030303030303035353630303030303038343838303131613161316131613161316131613164353538396138396138396138353232646464646464646435643535353532320a3564353535353232656565656565656565656532323232326666666666666666666666656565656530303030363030303030303030303238653830303030303030353536303030")
    (hex 46592 "3030303038343838303131316131613161316131613161313130353564396138396138396164353230353535353535353535643535353532320a35643535353532326666666666666666666666656565656566666666666666666666666565656565303030303036303030303030303038303238653030303030353536303030303030303834383830303131313161316131613161316131313130323535646138396138396435323230353535353535353535643531643532320a356435353535323266666666666666666666666565656565666666666666666666666665656565653030303030303630303030306538303265303065303035353536303030")
    (hex 46848 "30303030303834383830303131313131613161316131613131313130303235356464396164643532323030353535353535353535643564353532320a35643535353532326565656565656565656565323232323266666666666666666666666565656565303030303030303636303065303832653030303535353536363030303030303030383438383030303131313131316131613161313131313130303032353535646435353232303030353535353535353535643535353532320a35643535353532326666666666666666666666656565656566666666666666666666666565656565303030303030303030363636303038326538303536363630303030")
    (hex 47104 "303030303030383438383030303131313131313161316131313131313130303030323535353535323230303030323232323232323235643535353532320a35643535353532326666666666666666666666656565656566666666666666666666666565656565303030303030303030303030363636363636363630303030303030303030303030303834383830303131313131313131613131313131313130303030303032323232303030303030323232323232323235643535353532320a3136323632363236323632363236323632363236323632363337333733373337333733373337333733373337333733373337333733373337333733373337333733")
    (hex 47360 "3733373337333733373337333733373337333733373337333733373337343733373337333733373337333733373337333733373337333733373337333733370a33373337333733373337333733373337333733373337333733373337333733373337333734363337333733373436303633373337333733373337303433373337303730303030613762373030303030303030303030306137623730303030303730373030303730303030303030303030303030303030303030303037303030370a613739353935393539353136343633373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733")
    (hex 47616 "37333733373337333733373337333733373337333733373337333734363337343730363337303634363036333733373036333733373337303633373337333733370a33373337333733373337303633373337333733373337333733373337333733373236323632363236323632363436333733373337343633373337333733373337303730303030303030303030303030303030303030303030303030303030303730376136303761366136613661366136613661366136613661363037613630370a30306137393539353935393533373036333733373036333733373036333733373337333733373036333733373036333733373337333733373337343633")
    (hex 47872 "373337333734363337333733373337333733373337333733373337333733373036343733373337343630343436333730363436333733373236323632363236323632360a32363236323632363236323632363236343633373337333730363337333733373336393539353935393562363136323632363236333730363337333734363337303730303030303030303030303030303030303030303030303030303030303730376237303762376237623762376237623762376237623762373037623730370a3030303030306237613739353436333733373436333730363337333733373337333733373337333733373337333733373337343633373337333730")
    (hex 48128 "3633373337333733373337333733373337343633373337333733373436303633373337343733373337303634363337303633373337333730363236333639353935393539350a39353935393539353935313632363236323630363337333733373337333733373935393539353935393539356236313632363236323632363236333733373337303730303030613662363030303030303030303030306136623630303030303730373030663730303030303030303030303030303030303030303037303030370a303030303030303030303935313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731")
    (hex 48384 "37313731373137313731373137313731373137313731373137313731373137313731373137323731373137313731373137313731373137313732373935393539353935393539350a39353935393539353935393539353935393531373137313731373137313731373935393539353935393539353935623630303030303031373137313731373137303739353935393539353935393539353935393539353935393539353935303730373030303730303030303030303030303030303030303030303037303030370a30303030303030303030613731353135313531353135313531353135313531353135313531353135313531353135313531353135313531")
    (hex 48640 "353135313531353135313531353135313531353135313531353135313531353135313531353135333531353135313531353135313531353135313533353935393539353935393539350a39353935393539353935393539353935393531353135313531353135313531353935393561373935393539353935393530303030613631353135313531353135663730303030613762373030303030303030303030306137623730303030303730376537653732356236623662366236623662366236623632356537653730370a3030303030303030303030303137313731373137313731373137313731373137313731373137313731373137313731373137313731")
    (hex 48896 "3731373137313731373137313731373137313731373137313731373137313731373137313731373137323731373137313731373137313731373137313732373935393539353935393539350a39353935393539353935393539353935393531373137313731373137313731373935623639353935393539353935393562363935393531373137313731373137303730303030303030303030303030303030303030303030303030303030303730376137613730376137613761376137613761376137613730376137613730370a303030303030303030306136343630363337333730363436333733373337303433373337333733373337333730363436333733")
    (hex 49152 "37333733373337333733373337333733373436333733373337343633373036343633373337343633373036333633373337303632363236323632363236323633363935393539353935393539350a39353935393539353935393539353935393531363236323630363337303633373935393539353935393539353935393539353935393531363236323630363337303730303030303030303030303030303030303030303030303030303030303730373030303030373030303030303030303030303030303030373030303030370a30303030303030306136393531353135313531353135313531353135313531353135313531353135313531353135313531")
    (hex 49408 "353135313531353135313531353135313531353135313531353135313531353135313531353135313531353335303031353135313533353935393539353935393539353935393539353935393539350a39353935393539353935393539353935393539353935393531353135313531353935393539353935393539353935393539353935393539353935313531353135303730303030303030303030303030303030303030303030303030303030303730373030303030373030303030303030303030303030303030373030303030370a3030303061363935393539353036333730363337333733373337333733373337333733373337333733373337333730")
    (hex 49664 "3633373337333733373337333733373337333733373337323632363236323632363236323632363236323632363336303033373436333734373935393539353935393539353935393539353935393539350a39353935393539353935393539353935393539353935393531363337343633373935393539353935393539353935393539353935393539353935333733373036303730303030303030303030303061366236303030303030303030303030663730376136623630376236613662366136623661366236613666376136623630370a303030303935393539353134323433373337343633373337333733373337333733373337333733373337333733")
    (hex 49920 "37303633373337333730363337333734363337333733373337333734363337333733373436303633373337333734376237303033373337333734373935393539353935623730303030613639353935393539350a39353935393539356237393561373935623761373935393539353337333733373935393539353935393539353935393539353935393539353134323433373337323565376537323539353935393539353935393539353935323565376537323530376237613730376137623761376237613762376137623730376237613730370a30306136393562373935313731373137313731373137313731373137313731373137313731373137313731")
    (hex 50176 "373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313732373030303031373137313732373935393539353935303030306136393539353935393539350a39353935623730306136393562363030613662366137623730303137313731373935393539353935393539353935393539353935393539353137313731373137303730303030303030303030303061376237303030303030303030303030303766376537653765373235303030303030303030303030323565376537653730370a3030393539356136393530363337333733373337333733373337333733373337333733373337333730")
    (hex 50432 "3633373337333733373337333733373337333733373337333733373337333733373337333733373337303633373337343634373030303033373337333733363935393539353935623639353935393539353935393539350a39356237613639353935393539353935393539356236613639353337333733373935393562376137393539353935393539353935393539353337343633373337303730303030303030303030303030303030303030303030303030303030303730373030303030303037303030303030303030303030303730303030303030370a303039353935393531343434323433373337333733373436333733373337333733373337333733")
    (hex 50688 "37303633373337333733373337303633373337333733373337343633373337333733373036333733373337333733373337303434373030303034363337343739353935393539353935393539353935393539353935313432340a34343334393539353935393539353935393539353935393539353436343633373434323433346236613739353935393531343234323432343036343530363337303730303030303030303030303030303030303030303030303030303030303730376136613661363037613661366136623662366236303762366236623630370a61363935313432343234333733373337333733373337333733373337333730363337303633")
    (hex 50944 "373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337303633373337333734376236303030363436343739353935393539353935393539353935393539353134333733370a30363337333439353935393539353935393539353935393539353036333733373436333732343234343432343234343430363436333730363337343630363337303730303030613662363030303030303030303030306136623630303030303730376137613761373037613761376137623762376237303762376237623730370a3134323430363436333733373337333733373337333733373436333733373337333734")
    (hex 51200 "3633373036343633373337333730363337343634363337343633373036333733373337333733373337333733373337333733373337333732343434333433373337343739353935393562373935393539353935393539353337343630360a34363337343739353935393539353935393539353935393539353337333733373337333733373337333734363337333733373036333733373337333733373337663739353935393539353935393539353935393539353935393539353935303730373030303030303037303030303030303030303030303730303030303030370a333733373337333733373337333733373337333733373337333733373337333733")
    (hex 51456 "37333733373337333733373337333733373337333733373036333733373337303030303030303030303030303030303030303030303030303030303030303033373337343739353935393539353935393539353935393539353036333733370a34353036343739353935393539353935393539353935393539353337333733373030303030303030303030303030303030303030303030303030303030303030303732353030613762373030303030303030303030306137623730303235303765376537653765376537323562366236613661363235653765376537653765370a30363337303633373337333730363337333733373036333733373436333733")
    (hex 51712 "373337333733373337333733373337333733373337343633373337333733373337303030303030303030303030303030303030303030303030303030303030303033373337343739353935393539353935393539353935393539353136333730360a34363337333639353935393539353935393539353935393539353337303633373030303030303030303030303030303030303030303030303030303030303030303730373030303030303030303030303030303030303030303030303037303730373037303730376537303739353935393539353037653730373037303730370a3337333733373337333733373436333733373337333730363337303633")
    (hex 51968 "3732363337333733373337333733373337333733373337333733373337333733373337303030303030303030303030303030303030303030303030303030303030303033373036343739353935393539353935393539353935393562373030313632360a32363336393539353935393539353935393539353935393539353337333733373030303030303030303030303030303030303030303030303030303030303030303730373030303030303030303030303030303030303030303030303037303730373037663730376537323539353935393539353235653730376637303730370a343630363337333732363236323632363236323632363236323632")
    (hex 52224 "36333639353337333733373036333734373337333733373437333733373337303633373337303030303030303030303030303030303030303030303030303030303030303034363036323433343935393539353935393539353935393530303030303039350a39353935393539353935393539353935393539353935313432343337343630363030303030303030303030303030303030303030303030303030303030303030303730373030303030303030303061366236303030303030303030303037303730373037303732353935393539353935393539353935393532353037303730370a31373137313731373137323762376136393539353935393539")
    (hex 52480 "353935393539353137313731373137313732373137313731373237313731373137313731373137303030303030303030303030303030303030303030303030303030303030303031373137313732373935393539353935393561363935623730303030613639350a39353935393539353935393539353935393539353935313731373137313731373030303030303030303030303030303030303030303030303030303030303030303730373935393539353935393539353935393539353935393539353037303730373037323539353935393539356237613739353935393539353235663730370a3135313531353135333533363935393539353935393539")
    (hex 52736 "3539353935393539353135313531353135313533353135313531353335313531353135313531353135303030303030323532353235303030303030303030303235323532353030303031353135313533353935393539353935393539356237303030303935393539350a39353935393562373030613639353935393539353935313531353135313531353030303030303030303030303030303030303030303030303030303030303030663730373030303030303030303061376237303030303030303030303037303766373037393562373935393539353030303039353935393561373935303730370a313731373137313732373935393539353935393539")
    (hex 52992 "35393539353935393539353137313731373137313732373137323731373237313731373137313731373137303030303030323532353235303030303030303030303235323532353030303031373137313732373935393539356237303030303030303061363935393539350a39353935623730303030393539353935623739353935313731373137313731373030303030303030303030303030303030303030303030303030303030303030303730373030303030303030303030303030303030303030303030303037303730373037393539356237393539353030303039353935613739353935303730370a33373337333733373336393539353935393539")
    (hex 53248 "353935393539353935393539353337333733373036333734373337343733373437333733373337333733373337303030303030323532353235303030303030303030303235323532353030303033373436333732343334393539353030303030306136393539353935393539350a39353935303061363935393539353935303030303030333733373036333733373030303030303030303031343234343432343434343432343334303030303030303765373235303030303030323565376537323530303030303032356537303730373235393539353935623739353030303039356137393539353935323530370a3135313531353335393539353935393539")
    (hex 53504 "3539353935623739353935393539353135313531353135313533353135333531353335313531353135313531353135303030303030303730373037303030303030303030303037303730373030303031353135313531353335393562373030303039353935393539353935393539350a39353935393539353935393539356237303030303030313531353135313531353030303030303030303030363337333734363337333730363437303030303030303730303037613662363030303739353935663730306136623630373030303730373935393539353935393562373030303061373935393539353935393566370a333733373337323432343334393539")
    (hex 53760 "35393539353935393539353935393539353337303632363236303634373337343733373437323632363337333733373337303030303030303730373037303030303030303030303037303730373030303033373337303634363234323434343434333461373935393539353935393539350a39353935393539353935623730303030303030303030333730363436333733373030303030303030303031373137313731373137313731373237303030303030303739353037393539353935323565376537323539353935393530373935303730373935623730303030303030303030303030303030303030306137393530370a33373337343633373234323434")
    (hex 54016 "343434323434343334393539353935393539353036343739356237343634373036343733373437393562373337303633373337303030303030303730373037323434343334303030303037303730373334303033373337343630363337333733373337323432343234333439353935393539350a39353935393531343434333430303030313434343434333733373337333733373030303030303030303031363236323632363236323632363336303030303030303730306637613762373030303030303030303030306137623730373030303730373935623630303030303030303030303030303030303030306136393530370a3137313731373137313731")
    (hex 54272 "3731373137313731373237393539353935393539353137323739353030313732373137323731373237393530303137313731373137303030303134303730373037303634363234323434343037303730373036333431373137313731373137313731373137313731373137323739353935393539350a39353935393531373137323731343334313731373137313731373137313731373030303030303030303030303030613739353935393539353030303030303030303730303037303030303030303030303030303030303030303066373030303730373935393539353935393562363030303061363935393539353935393530370a333733373337333733")
    (hex 54528 "37333733373337333733373337323434343234333439353337343739353030303634373136333634363437393530303337333730363337313434343436303766373037343633373036333730363037303730373436303633373337333733373337333730363337333733373337333732343434333439350a39353935393533373036343730363437333730363436333730343337333733373030303030303030303030303030303030303030613762373030303030303030303730303037303030303030303030303030303030303030303030373030303766373235393539353935623639353037303739356136393539353935323530370a33373337333733")
    (hex 54784 "373337333730363436333733373337333733373337333732343337343762373030313633363030303030363437623730303136323633373337333732356537323565373235653732353436323565373235653732356537323533373337333733373337343633373436303633373337333733373036343632340a34343434323432343337343733373337333733373337333733373337333733373030303030303030303030303030303030303030303030303030303030303030303730303037303030303030303061366236303030303030303066373030303730373037393539356236393539353037303739353935613639353935303730370a3337333730")
    (hex 55040 "3633373337333730363436303633373036333733373337333730363337343730303030303030303030303031363336303030303030303033373436343630373436303634363337333730373036663730363337343633373436303733373337333733373337333730363337303633373337333733373036333733370a30363337333733373337333733373337333733373337333733373337333733373030303030303030303030303030303030303030303030303030303030303030303739353037393539353935393539353935393539353935393530373935303730376637323562363935393532353235323532353935393561363235663730370a333733")
    (hex 55296 "37333733373337333733373337333733373337333733373337333733373236333630303030303030303030303030303030303030303030303031363236323565376537653765376537653765376537653765376537653765376537653733373337333733373337333733373337333733373337333733373337333733370a33373337333733373337333733373337333733373337333733373337333733373030303030303030303030303030303030303030303030303030303030303030303730303037303030303030303061376237303030303030303030373030303730373037303765376537653765376537653765376537653765373037303730370a5f")
    (hex 55552 "5f6c6162656c5f5f0a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 55808 "666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 56064 "6666666666666666666666660a66666666666666666666666666666666666666666666396666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666666666666666666666666639666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 56320 "66666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 56576 "666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666343434346666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663439666639346666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 56832 "6666666666666666666666666666666666660a66666639666666666666666666666666666666666666666666666639666666666666666666666666666666396666666666666666666666663466653434666534666666666666666666666639666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666634393439663439346666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 57088 "66666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663466346634666534666666666666666666666666666666666666666666663966666666666666666666666666666666666666666666666666666666666666396666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663439343965393465666666666666666666666666666666666639666666666666666666666666666666666666666666666666")
    (hex 57344 "666666666666663966666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663466653434346566666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663434656565666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 57600 "6666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 57856 "66666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 58112 "666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666639666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666639")
    (hex 58368 "6666666666666666666666666666666666666666666666666666666666660a65656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656666666666666666666666666666666666666666666666666666666666666666666666666666666665656565656565650a323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323266666666666666666666666666666666")
    (hex 58624 "66666666666666666666666666666666666666666666666632323232323232320a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031306666666666666666666666666666666666666666666666666666666666666666666666656565656531303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130316666666666666666666666666666")
    (hex 58880 "666666666666666666666666666666666666666666656565656530313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031306666666666666666666666666666666666666666666666666666666666666666666666656565656531303130313031300a3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031666666666666666666666666")
    (hex 59136 "6666666666666666666666666666666666666666666666656565656530313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031306566666666666666666666666666666666666666666666666666666666666666666666656565653231303130313031300a303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303132656666666666666666")
    (hex 59392 "66666666666666666666666666666666666666666666666666656565323230313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303132656565656565656565656565656565656565656565656565656565656565656565656532323131303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131323232323232")
    (hex 59648 "323232323232323232323232323232323232323232323232323232323232313130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 59904 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 60160 "30313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 60416 "303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 60672 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 60928 "30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 61184 "303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 61440 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 61696 "30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 61952 "303130313031303130313031303130313031303130313031303130313031303130313031303130313031313130313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303131313131303130313031303130313031300a3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 62208 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313131313031303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031313131313131313130313031303130313031300a303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 62464 "30313031303130313031303130313031303130313031303130313031303130313031303130313031303131313131313131313131303130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313031303130313031300a30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 62720 "303130313031303130313031303130313031303130313031303130313031303130313031303130313031313131313131313131313131313130313031303130310a31303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313131313031303130313031300a3031303838313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 62976 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031313131313131303130383831303130310a31303838383831303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313130313038383838313031300a303138383438303130313031303130313031303130313031303130303030303130313030303030313031303030303031303130303030303130313030")
    (hex 63232 "30303031303130303030303130313030303030313031303030303031303130303030303130313031303130313031303130313031313131313031303138383438303130310a31303838343831303130313031303130313031303130313031303030373730303130303730373030313030303737303031303037373730303130303737303030313030373737303031303037373730303130303037373030313030373037303031303130313031303130313031303130313131303130313038383438313031300a30313038383438313031303130313031303130313031303130313037303030313031303730373031303130373037303130313037303730313031")
    (hex 63488 "303730373031303130373030303130313030373030313031303730303031303130373037303130313031303130313031303130313031313130313031303130383834383130310a31303138383438303130313031303130313031303130313031303037373730303130303730373030313030373037303031303037373030303130303730373030313030373730313031303130373031303130303737373030313030373737303031303130313031303130313031303130313031303130313031383834383031300a3031383834383031303130313031303130313031303130313031303030373031303130373737303130313037303730313031303730373031")
    (hex 63744 "3031303730373031303130373030303130313030373030313031303030373031303130373037303130313031303130313031303130313031303130313031303138383438303130310a31303838343831303130313031303130313031303130313031303037373030303130303737373030313030373730303031303037303730303130303737373030313030373030313031303037373730303130303737303030313030373037303031303130313031303130313031303130313031303130313038383438313031300a303838343831303130313939303130313031303130313031303130303030303130313030303030313031303030303031303130303030")
    (hex 64000 "30313031303030303031303130303031303130313030303030313031303030303031303130303030303130313031303130313031303130313031303139393031303838343831303130310a31383834383031303139393939303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313939393930313838343830313031300a30313838343830313039393439313031303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 64256 "303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303939343931303138383438303130310a31303838343831303139393439303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313939343930313038383438313031300a3031303838343831303139393439303130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 64512 "3031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303139393439303130383834383130310a31303138383438303130393934393130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313039393439313031383834383031300a303138383438303130393934393130313031303130313031303130313031303130313031303130313031303130313031")
    (hex 64768 "30313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303939343931303138383438303130310a31303838343831303139393439303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131303130313031303130313031303130313939343930313038383438313031300a30383834383130313939343930313031306161313031303130313031303130313031303130313031303130313031")
    (hex 65024 "303130313031303130313031303130313031303130313031303131313131313131313131313131313131313131313131313130313031303130313031306161313031393934393031303838343831303130310a31383834383031303939343931303130616161613130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131303130313031303130616161613130393934393130313838343830313031300a3031383834383031303939343931303161613461303130313031303130313031303130313031303130313031")
    (hex 65280 "3031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313130313031303130313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031303131313131313131313131313131313131313131313131313131313131303130313031303130616134613130313939343930313038383438313031300a303130383834383130313939343930313061613461313031303130313031303130313031303130313031")
    (hex 65536 "30313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131313130313031303130313031306161346131303139393439303130383834383130310a31303138383438303130393934393130316161346130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313131313131303130313031303130316161346130313039393439313031383834383031300a30313838343830313039393439313031616134613031303130313031303130313031303130313031")
    (hex 65792 "303130313031303130313031303130313031303130313031303131313131313131313131313131313131313131313131313131313131313130313031303130313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130313031303130313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131313131313031303130313031303130616134613130313939343930313038383438313031300a3038383438313031393934393031306161346131303130316666303130313031303130313031")
    (hex 66048 "3031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313131313131303130313031666630313061613461313031393934393031303838343831303130310a31383834383031303939343931303161613461303130316666666630313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131313130313031303166666666303161613461303130393934393130313838343830313031300a303138383438303130393934393130316161346130313066663466313031303130313031")
    (hex 66304 "30313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313131313031303130313066663466313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130316666346630313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131303130313031303166663466303130616134613130313939343930313038383438313031300a30313038383438313031393934393031306161346131303166663466303130313031")
    (hex 66560 "303130313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313130313031303130313031666634663031306161346131303139393439303130383834383130310a31303138383438303130393934393130316161346130313066663466313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313031303130313031303130666634663130316161346130313039393439313031383834383031300a3031383834383031303939343931303161613461303130666634663130313031")
    (hex 66816 "3031303130313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131303130313031303130313066663466313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130316666346630313031303130313031303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313031303130313031303166663466303130616134613130313939343930313038383438313031300a303838343831303139393439303130616134613130316666346630313031")
    (hex 67072 "30373731303130313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131303130313037373130316666346630313061613461313031393934393031303838343831303130310a31383834383031303939343931303161613461303130666634663130313037373737313031303130313031303130313031303130313031303130313031303131313131313131313131313131313131313131313131313131313031303737373731306666346631303161613461303130393934393130313838343830313031300a30313838343830313039393439313031616134613031306666346631")
    (hex 67328 "303137373437303130313031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131303130313737343730313066663466313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130316666346630313037373437313031303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313131313031303737343731303166663466303130616134613130313939343930313038383438313031300a3031303838343831303139393439303130616134613130316666")
    (hex 67584 "3466303130373734373130313031303130313031303130313031303130313031303131313131313131313131313131313131313131313131313131313131303130313037373437313031666634663031306161346131303139393439303130383834383130310a31303138383438303130393934393130316161346130313066663466313031373734373031303130313031303130313031303130313031303130313131313131313131313131313131313131313131313131313131313131313031303137373437303130666634663130316161346130313039393439313031383834383031300a303138383438303130393934393130316161346130313066")
    (hex 67840 "66346631303137373437303130313031303130313031303130313031303130313031313131313131313131313131313131313131313131313131313131313131303130313737343730313066663466313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130316666346630313037373437313031303130313333333333333333333333333333333333333333333333333333333333333333333333333333313131313131313130313031303737343731303166663466303130616134613130313939343930313038383438313031300a30383834383130313939343930313061613461313031")
    (hex 68096 "666634663031303737343731303130313031333335333533333535333533333533353533353333353335353335333335333535333533353333333131313131313031303130373734373130316666346630313061613461313031393934393031303838343831303130310a31383834383031303939343931303161613461303130666634663130313737343730313031303130333565356533356565356535336535656535653533653565653565353365356533356535323535333131313131303130313031373734373031306666346631303161613461303130393934393130313838343830313031300a3031383834383031303939343931303161613461")
    (hex 68352 "3031306666346631303137373437303130313031356566666635656666656665356665666665666535666566666566653566656635656632653232333131313130313031303130313737343730313066663466313031616134613031303939343931303138383438303130310a31303838343831303139393439303130616134613130316666346630313037373437313031303130656666666666666666666666656666666666666665666666666666666566666665666665656565353131313031303130313031303737343731303166663466303130616134613130313939343930313038383438313031300a303130383834383130313939343930313061")
    (hex 68608 "61346131303166663466303130373734373130313031666666666666666666666666666666666666666666666666666666666666666666666665656565323131303130313031303130313037373437313031666634663031306161346131303139393439303130383834383130310a31303138383438303130393934393130316161346130313066663466313031373734373031303130666666666666666666666666666666666666666666666666666666666666666666666665656565653130313031303130313031303137373437303130666634663130316161346130313039393439313031383834383031300a30313838343830313039393439313031")
    (hex 68864 "616134613031306666346631303137373437303130313031666666666666666666666666666666666666666666666666666666666666666666666665656565653031303130313031303130313737343730313066663466313031616134613031303939343931303138383438303130310a33333333333333333333333333333333333333333333333333333333333333333333333333333333666666666666666666666666666666666666666666666666333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333330a3333353533333333353335333335")
    (hex 69120 "3335353335333335333533333535333333333333353533333333666666666666666666666666666666666666666666666666353335333335333535333533333533353533353333353335333335353333333333333535333333333533353333353335353335333335333533333535333333330a33356565353335356535653533653565653565353365356533356565353335353335656535333535666666666666666666666666666666666666666666666666653565353365356565356535336535656535653533653565333565653533353533356565353335356535653533653565653565353365356533356565353335350a356566666535656566656665")
    (hex 69376 "35666566666566653566656635656666653565653565666665356565666666666666666666666666666666666666666666666666666566653566656666656665356665666665666535666566356566666535656535656666653565656665666535666566666566653566656635656666653565650a65666666666566666666666665666666666666666566666665666666666566666566666666656666666666666666396666666666666666666666666666666666666666666566666666666666656666666666666665666666656666666665666665666666666566666666666665666666666666666566666665666666666566660a66666666666666666666")
    (hex 69632 "666666666666666666666666666666666666666666666666666666666666663966666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666")
    (hex 69888 "6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666")
    (hex 70144 "66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666396666666666666666666666666666666666666666666666666666666666666666666666666666663966666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666")
    (hex 70400 "666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666")
    (hex 70656 "6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a")
    (hex 70912 "66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 71168 "660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a6666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666396666666666666666666666666666666666")
    (hex 71424 "6666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a666666666666666666666666666666666666666666666666666666666666666666666666666639666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663966666666")
    (hex 71680 "66666666660a66666666666666666666666666666666666666666666666666666666666666666639666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666663966666666666666666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666")
    (hex 71936 "666666666666660a66666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660a0a5f5f6766665f5f0a3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 72192 "30303030303030303030303030303030303030333033303330333033303030303030303030303030303030303030303030303033303330333033303330303030303030303031303030303030303030303030303330333033303330333030303030303030303030313031303030303030303030333033303330333033303030303030303030303031303130303030303330330a30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 72448 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a5f5f6d61705f5f0a30303030303030303030303030303030303030303030303030303030303030303733363036323632363236323632363236323632363236323632363237333630303030303030303030303030303030303030303030303030303030303030303036313632")
    (hex 72704 "3632363237333634373337333733373337333733373337333733373337333733363437333733373337333733373337333733373337333733373337333733373337333733373337333733373337343731373137313732363037333733373337333733363037333733373337333733373336343630373337333733373337333733363437333733363037333733363036343733373337333632363236330a303030303030303030303030303030303030303030303030303030303030303036343633303030303761353937623030376135393762376135393539363137333030303030303030303030303030303030303030303030303030303030303030376135")
    (hex 72960 "393762303037333630373336323632373336343733373337333733373336303733373336303733363037333534373336303634373337333733363437333733373337333733363437333733373337343733363037333734373336303733363236323632363236323632363236323632363236323632363236323632373337333733373337333634373337333632363236323632363236333539353935390a3030303030303030303030303030303030303030303030303030303030303030373435393662303030303539366230303030353930303030353935393762373330303030303030303030303030303030303030303030303030303030303030303030")
    (hex 73216 "35393662303036313632363335393539363136323632363236323632363236323632363236323632363236323632363236323733373336343733373336323632363236323632363236323632363236333531353135313533363136323632363335393539353935393539353935393539353935393539353935393539363136323632363236323632363236323632363335393539353935393539353937620a30303030303030303030303030303030303030303030303030303030303030303734353935393662303035393539303036613539366230303539353930303634303030303030303030303030303030303030303030303030303030303030303030")
    (hex 73472 "3035393539366235393030353937623761353935393539353935393539353935393539353935393539353935393539353935393631363236323632363335393539353935393662366236613539353935393731373137313732353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393661353935393762303030300a303030303030303030303030303030303030303030303030303030303030303037323761353935393030353935393030353937613539303035393539366237313030303030303431343234333030303030303030303030303030303030303030")
    (hex 73728 "303037613539353937623030353930303030353935393662366135393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393731373137313732353935393539353935393539353935393539353935393539353935393539353935393539353936623761353937623761353935393539353935393539353937623030303030300a3030303030303030303030303030303030303030303030303030303030303030353330303761353936623539376230303539303035393030376135393539353130303030303036313632363336623030303030303030303030303030303030")
    (hex 73984 "30303030303761353930303030353936623661353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393631363236323633353935393539353935393539343134343432343434343432343234343433376135393539353935393539353930303030303037613539353937623761353936623030303030300a30303030303030303030303030303030303030303030303030303030303030303732303030303539353935393661353935393662353930303030303037613731303030303030303037613539353930303030303030303030303030303030")
    (hex 74240 "3030303030303661353930303661353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393762376135393539353935393539353935393539353935393539353935393539353935393539353935393539373337333733363036343733373337333734303035393539353935393539376230303661366230303539353930303030353935393030303030300a303030303030303030303030303030303030303030303030303030303030303037343662303037613539353935393539353935393539303030303030366137333030303030303030303037613539353936623030303034313434343330")
    (hex 74496 "303030303030303539353930303539353935393762366235393762303030303539353935393539353935393539353935393539353935393539353935393539366135393539353935393539353935393539353935393539353935393539353935393539353935393539373137313731373137313731373137313732303036613539353935393539366236613539353935393539353936623030353935393030303030300a3030303030303030303030303030303030303030303030303030303030303030373235393662303035393539353935393539353937623030303036613539353130303030303030303030303035393539353930303661373137313732")
    (hex 74752 "30303030303036613539376230303539376135393539353935393030303030303539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393762363035343630373337333733363437333734366135393539353935393539353935393761353935393539353935393539353935393030303030300a30303030303030303030303030303030303030303030303030303030303030303734376135393662353935393761353935393539366230303661353937623733303030303030303030303030353935393539353935393631363236")
    (hex 75008 "3330303030303037613539366230303761353935393539353937623030303036613539353935393539353935393539353935393539376230303030303035393539353935393539353935393539376235393539353935393431343234343433353935393539353935393662353135313531353135313531353135313533353935393539353935393762376135393539353930303761376230303030366135393662303030300a303030303030303030303030303030303030303030303030303030303030303037343030376135393539376230303761376237613539303037613539303036303030303030303030303030303761353935393539353935393762")
    (hex 75264 "303030303030303030303539353930303030353937613539353930303030303035393539353935393539353935393539353935393539303030303030366135393539353935393539353937623030303037613539353935393733363037333734353935393539353935393539363136323632363236323632363236323633353935393539353935393030366135393539353936623030303030303030376135393539303030300a3030303030303030303030303030303030303030303030303030303030303030373230303030376135393030303036613662303035393030303035393030373130303030303030303030303036613539353935393762303030")
    (hex 75520 "30303030303030303036613762376136623030353930303539353930303661353935393539353935393539353935393539353935393762303030303030353935393539353935393539353930303431343330303539353935393531353135313533353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393539353935393662366135393539366230300a30303030303030303030303030303030303030303030303030303030303030303734303030303030353930303030353937623030353930303030353930303733303030303030303034313434343335393762303030303030")
    (hex 75776 "3030303030303030303035393030303035393030353936623431343234343432343335393539353935393539353935393539343134323432343234333661353935393539353935393539376230303630373430303761353935393731373137313732353935393539353935393539353935393539353935393539353935393539353935393539353934313432343234323432343335393539343134323434343434323433353936620a303030303030303030303030303030303030303030303030303030303030303037343030303030303539303036613539303030303539303030303539366237333030303030303030363136323633376230303030303030")
    (hex 76032 "303030303030303030366135393662366135393662343134323434343234323434343434343432343234343432343234343434363437333733343234323432343434343432343234343434343234323432343234323432343234323432343234323432343234323432343335393539353935393539353935393539353935393539353935393539343134323432343234343434343234323432343234323432343234343632343335390a3030303030303030303030303030303030303030303030303030303030303030373434333030366135393662353937623030366135393662366135393431373330303030303030303030303030303030303030303030")
    (hex 76288 "30303030303030303030343134323432343434343432373334303733363437333733373337333630373337333733363037333733373337333630373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733343234323432343234343432343234343432343234343434343434323434363037333733373336343733373335303733363036343434343434343432343234330a30303030303030303030303030303030303030303030303030303030303030303630373434313432343434343432343434343432343434323432343437333733303030303030303030303030303030303030303030")
    (hex 76544 "3030303030303030303030373337333733363037333733363037333733363037333733373337333634373337333733373337333634373337333733373337333733373337333630363437333733373337333733373337333733373337333733373337333733373337333733373337333733373337333634373337333733363037333733373337333733373337333733373336303733373337333733373337333733373337333733363037340a303030303030303030303030343134343432343234343432343234343432343434313432343434333030303030303030303030303431343234343434343234323434343234343432343434323432343434343432")
    (hex 76800 "343234333030303030303030373337333734353935393539353935393539353935393539353937333733373337333634373435393539353935393539353935393539353935393733373337333733363437343539353935393539353935393539353935393539363437333733303030303030303030303030303030303030303030303734373437343733373334323433353935393662303030303030303030303030303036613539353934310a3030303030303030343134343432373337333634373337333630373336303630373337333432343434323434343434333030303037333630373336343634373337333733373337333733363036343733373337")
    (hex 77056 "33363437343030303030303030373337333432343335393539353935393539376235393539353937333733373337333630373435393539353935393539353935393539353935393634373336303733373337343539353935393539353935393539353935393539373336303733303030303030303030303030303030303030303030303633373437343630373337333734353935393539353935393539353935393539353935393539353936340a30303030303034313432343237333733373337333733363435343630373337333733373336303733363437333432343434343434343237333630343036303733373337333733373337333630353036343733")
    (hex 77312 "3733343234323433303030303030373336343630373435393539353935393539303036613539353937333634373337333733343234333539353935393539353935393539353935393630353036343733363037343539353935393030303030303761353935393539373336343733303030303030303030303030303030303030303030303761363337343733373337333432343335393539353937623030303030303030376135393539343136300a303034313432363437333733373337333733373337333630363437333733373337333733373337333733373337333733373336303733373337333630363037333733373337333733373337333733373337")
    (hex 77568 "333630373336303432343234333030373337333630363335393539353935393539303035393539353936313733363037333733363034323433376135393539353935393539353935393733363037333632363236333539353935393030343134343432343234343434343237333733303030303030303030303030303030303030303030303030353937323731373237333733343234333539303030303030366135393539353935393431363036300a3030373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731")
    (hex 77824 "37313731373137313731373137323030373137313732353935393762303035393539353935393539353935393731373137313731373137313732366236613539353935393539353935393731373137313731373235393539353935393030373137313731373137313731373137313731303030303030303030303030303030303030303030303030353936333733373437313731373137323539366230303661353935393539353935393731373137310a30303531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135")
    (hex 78080 "3135313531353135313531353135333030353135313533353935393539376236613539353935393539353935393531353135313531353135313533353935393539353935393539353935393531353135313531353335393539353935393662353135313531353135313531353135313531303030303030303030303030303030303030303030303030376135393634373435313531353135333539353935393539376135393539353935393531353135310a303037313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731")
    (hex 78336 "373137313731373137313731373137323030373137313732353935393539353935393539353935393539353935393731373137313731373137313732353935393539353937623539353935393731373137313731373235393539353935393539373137313731373137313731373137313731303030303030303030303030303030303030303030303030303035393631363337313731373137323539353935393030303035393539353935393731373137310a3030363136323632363236323632363236323733373337333630363037333733373337333733373337333630373337333733363437333733373337333733373336303733373337333733373337")
    (hex 78592 "33373336343630363236323632363236333030363436343432343335393539353930303761376237613539353934313733373337333630373337333734353935393539376230303761353935393631363237333630373435393539353935393539363137343734363236323632363237333733303030303030303030303030303030303030303030303030366135393539366237333733343234323433353935393662303030303761353934313733363037330a30303761353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531353135313531")
    (hex 78848 "3531353135313531353135313533353937623030353135313531353335393762353936623030303030303539353935313531353135313531353135313533353935393539303030303030303035393539353935313531353335393539353935393539353936333633353935393539353135313531303030303030303030303030303030303030303030303030376135393539353935313531353135313533353935393539353936623030353935313531353135310a303030303733373337333733373337333733373337333733373337333630373337333733373337333733373336303733373337333634363436303733373337333733373337333733373337")
    (hex 79104 "333733373337333733373337333734353936623030373337333733373435393661353935393662303036613539353936303733363037333733363036323633353935393539303030303030303035393539353936303733343234333539353935393539353935393539353935393539363137333733303030303030303030303030303030303030303030303030366135393539376237333733373336343734353935393539353935393539353936303630373337330a3030303037333733373337333634373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733")
    (hex 79360 "37333733373337333630363437333734353935393030373336343632363335393761353935393539353935393539376236313733353436303733373337343539353935393539353936623030366135393539343137333733343037343539353935393539353935393539353935393539353937333733303030303030303030303030303030303030303030303030353935393539303037333733363437333633353937623030353935393539353936313733373336300a30303661373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137313731373137")
    (hex 79616 "3137313731373137313731373137313732376135393030373137313732353935393030303030303030303030303030303035393731373137313731373137323539353937623030303037613539353935393539373137313731373137323539353935393539353935393539353935393539353937313731303030303030303030303030303030303030303030303030376135393539366237313731373137323539353936623539353935393539353935393731373137310a303034313733373337333733373337333733373336343733373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733")
    (hex 79872 "373337333733373337333733373334323434343335393030373336303734353935393539366230303030303030303030366135393631363437333733373337343539353930303030303030303539376135393431373337333733373334323432343434343434343234333539353935393539343134323733303030303030303030303030303030303030303030303030376136613539353937333733373337343539353937623761376135393539353935393733373337330a3431343234323432343234323432373337333733373337333733343037333733373337333733373337333733373337333733373337333733373337333733373337333733373337")
    (hex 80128 "33373337333733373337333733373337333733373435393662373336343633353936613539353935393539353935393539353937623539373337333630363036333539353936623030303030303539366230303733363037333733373336323632363236323734363236333539353935393539373337333733343234333030303030303030303030303030303030303030353935393431343437333630373336333539353930303030366135393539353935393733363037330a37333630373337333634373337333634373337333733373337333733373337333733373337333733363437333733373337333733363437333733373337333733373337333733")
    (hex 80384 "3733363437333733373337333733373337333733343234343433343037343539353935393539376230303030376135393539353935393539373337333634373435393539353935393539366230303539353935393630363437333733373337343539353937343633353935393539353935393539373337333733353135333030303034313433366230303431343434333661353935393630343036303634373435393539353936613539353935393539353935393634373336340a373337333733373336303733373337333733373337333733373337333733373337333733373337333733373337333733373337333733373337333733363037333733373337")
    (hex 80640 "333733373337333733373337333733373337333733373336343734363236333539376230303030303030303030303030303030303037613539363137333733373435393539353935393539353935393539353935393733373337333733373337343539353936333539353935393539353935393539373337333733373337343662366136303734353935393634373337343539353934313733373337333733373435393539353935393539353935393539353935393733363037330a5f5f7366785f5f0a303131343030303030353631313038363231306336323130633632313063363231306336323130623633313062363331306336333130653634313066")
    (hex 80896 "3634313132363431313536343131383635313162363631316236353131633636313161363731313836373131353637313133363731313036363130653635313062363531303936343130383633313037363231303636323130353631313033363131303236313130313631310a303130343030303030613035313063303531306630353131313035313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 81152 "3030303030303030303030303030303030303030300a3031303430303030306530353131303035313132303531313330353130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030303430303030313330353131353035313137303531313930353132303535333238353033303030303030303030303030303030303030303030303030303030")
    (hex 81408 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031303430303030323235353331653535333161353533313635353331333535333066353533306435353330333530303031353030316230303031383030303136303030313230303030663030303064303030303830303030363030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 81664 "303030303030303030303030303030300a3031303630303030306130353030613035303031303530303130353030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30313034303030303239343533313230353333313435333230353533323730353333363635373030303030303030303030303030303030303030303030303030303030303030")
    (hex 81920 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30313034303030303232343531323234353132363435313236343531323136353432323635313230363535323131303030303030303231313030323131303030303030303030303030323131303032313130303030303030323131303032313130303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 82176 "30303030303030303030300a3031313030303030303136313130313631313031363131303336313130353631313034363131303136313130313631313032363131303436313130353631313034363131303336313130323632313031363331303136323130313632313031363231303136313130313631313031363131303136313130323631313033363231303636323130353632313034363231303336323130333632313034363131303136313130313631310a303130313030303030353035333035303533303530353330343035333034303533303430353330323035333032303533303230353330303035333030303533303030353330303030303030")
    (hex 82432 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303131303030303031313433303131343330313134343031313434303131343530313134363031313436303131343630313134373031313437303131343730313134373031313437303131343630313134363031313435303063343630306334363030633437303063343730306334373030633437303063343630306334353030633435303063343530306334353030633434303063343430306334343030633433")
    (hex 82688 "3030633433300a3031313030303030323132323232313232323231323232323132333232313233323231323432323132343232313235323231323532323132353232313235323231323532323132343232313234323231323332323132333231633236323163323532316332353231633235323163323432316332343231633233323163323232316332323231633232323163323232316332313231633231323163323132316332303231633230320a3031313030303030313831343131383135313138313531313831353132343135313234313531323431343132343133313138313631313831353131383135313138313531313831353131383135313138")
    (hex 82944 "313531313831343131333136313133313531313331353131333135313133313531313331353131333134313133313431313331333131333133313133313331313331323131333132313133313231313331313131333131310a3031313030303030323831313232383131323238313232323831323232383133323238313332323831343232383134323238313532323831353232383136323238313632323831363132383135323238313532323831353232383135323238313532323831353232383135323238313432323831333232383132323238313132323831313232383131323238313132323831313231633131323163313132316331313231633131")
    (hex 83200 "320a3031303430303030323931353331633135333065313533303031353030303035303030303530303030353030303035303030313033303031303330303130333030313033303031303330303130333030313033303031303330303130333030313033303031303330303130333030313033303031303330303130333030313033303030303030303030303030303030303030303030303030303030303030303030303030303030300a30313038303030303131303335303435333531313033353034353335313130333530343533353131303335303435333531313033353034353335313130333530343533353063303035303030303530303030353030")
    (hex 83456 "30303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030353030303035303030303530303030303030303030303030303030303030300a3031303430303030313335333032393735333163353130316135313031303531303130353130303035303030303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303030303530300a303131")
    (hex 83712 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303130333030303030633732333063373233306337323330633732333063373233306337333330633734333063373533306337363330633736333063373533306337343330633733333063373233306337323330633733333063")
    (hex 83968 "3733333063373433306337353330633736333063373633306337353330633734333063373333306337323330633733333063373333306337343330633734333063373333306337323330633732330a3030303330303030313137333331313734333131373533313137363331313736333131373533313137353331313734333131373433313137333331313734333131373433313137353331313735333131373533313137353331313735333131373633313137363331313736333131373533313137343331313734333131373333313137333331313733333131373433313137343331313734333131373533313137363331313735330a3031303330303030")
    (hex 84224 "303230323330333032333034303233303730323330383033333062303333306230333330383032333037303133303830323330393032333038303233303630333330363034333038303533306130363330623036333063303633306230353330393034333037303333303630333330353033333034303233303430323330353033333037303433303730333330363032333036303233303630313330363030330a3031303530303030333636343332373334353333363531333633343533333635313333363531323436323132343631313234363131313836313131383631353030303030303030303030303030303030303030303030303030303030303030")
    (hex 84480 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031303530303030333233353533343635313362333535333736353133343635313335333435333536343133623634313334363431336236333133393333353362363331333936333133373632313332333235333236323133623632313334363131333633313531383631313138363131313836313131383631313138363131313836313131383631313138363131313836313131383631313138363131313836313131383631310a30313035303030303063353231")
    (hex 84736 "31303533313166353431323335353132343533333234353030303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303035303130303530313030353031303030303030303030300a30313035303030303234353331323335333131663534313163353531313835343330303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 84992 "30303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031306130303030313134343031313435303131343630313134363031313436303131343630313134363031313435303131343430313134343031313433303131343330313134323031313431303131343130313134313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303130613030303031633232323163323232")
    (hex 85248 "3163323232316332323231633233323163323332316332343231633235323164323732316432363231643235323164323432316432333231643232323164323132316432313230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a303130613030303031383134313138313531313831353131383135313231313531323131353132313134313231313331313131353131313135313131313431313131333131313132313131313131313131313131313131313030303030303030303030303030303030")
    (hex 85504 "3030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031306130303030323831313232383131323238313232323831323232383133323238313432323831343232383135323239313532323931353232393134323239313332323931323232393131323239313132323931313230303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3031303630303030316430333431643037313164303731")
    (hex 85760 "316430313530303030303164303134316430313531383030303030303030313830303031643031343164303135316430303031383030303138303030313830303031643030303164303030313830303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030")
    (hex 86016 "303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a3030313030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030300a30313130303030303063303533336634313530303030303363363135")
    (hex 86272 "30633035333366333135336336313530303030303063303533336634313530303030303363363135306330353333663431353363363135303030303030633035333366333135336633313533633631353063303533336634313533633631353030303030306330353330303030303366333135336336313530633035333366343135336336313530303030300a30313130303030303063303533336632303030303030303363363135306330353333663230303363363135303030303030633035333366323030303030303033633631353063303533336632303033633631353030303030306330353333663230303366323030336336313530633035333366")
    (hex 86528 "32303033633631353030303030306330353330303030303366323030336336313530633035333366323030336336313530303030300a3031313030303030306330353332393435343236343435336336313530633035333266333435336336313532623335323063303533323833353232393435323363363135306330353333663230303363363135303030303030633035333366323030323933353033633631353063303533323833353033633631353239333530306330353332393434303236333535336336313530633035333030303030336336313530303030300a303131303030303030303134303030303230303031313030303130303030313430")
    (hex 86784 "3030303230303031313030303130303030313430303030323030303131303030313030303031343030303032303030313130303031303030303134303030303230303031313030303130303030313430303030323030303131303030313030303031343030303032303030313130303031303030303134303030303230303031313030303130300a303131303030303030343134303034303230303431313030343130303034313430303430323030343131303034313030303431343030343032303034313130303431303030343134303034303230303431313030343130303034313430303430323030343131303034313030303431343030343032303034")
    (hex 87040 "3131303034313030303431343030343032303034313130303431303030343134303034303230303431313030343130300a3031313030303030303731343030373032303037313130303731303030373134303037303230303731313030373130303037313430303730323030373131303037313030303731343030373032303037313130303731303030373134303037303230303731313030373130303037313430303730323030373131303037313030303731343030373032303037313130303731303030373134303037303230303731313030373130300a3031313030303030303531343030353032303035313130303531303030353134303035303230")
    (hex 87296 "303531313030353130303035313430303530323030353131303035313030303531343030353032303035313130303531303030353134303035303230303531313030353130303035313430303530323030353131303035313030303531343030353032303035313130303531303030353134303035303230303531313030353130300a3031313030303030303931343030393032303039313130303931303030393134303039303230303931313030393130303039313430303930323030393131303039313030303931343030393032303039313130303931303030393134303039303230303931313030393130303039313430303930323030393131303039")
    (hex 87552 "313030303931343030393032303039313130303931303030393134303039303230303931313030393130300a3031313030303030303231343030323032303032313130303231303030323134303032303230303231313030323130303032313430303230323030323131303032313030303231343030323032303032313130303231303030323134303032303230303231313030323130303032313430303230323030323131303032313030303231343030323032303032313130303231303030323134303032303230303231313030323130300a5f5f6d757369635f5f0a30302030303432343334340a30322030383432343334340a303420306130623063")
    (hex 87808 "30640a30302031323133343334340a30342031333134343334340a30342031393161316231630a30302034313432343334340a30302034313432343334340a30312032323233343334340a30302032323234343334340a30302032323235343334340a30302032323235343334340a30302032323236343334340a30302032323237343334340a30302032323235343334340a30322032323238343334340a0a")))
