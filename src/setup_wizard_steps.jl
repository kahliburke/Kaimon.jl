# ─────────────────────────────────────────────────────────────────────────────
# Kaimon setup wizard · config step layout · progress list · step content views  (split from setup_wizard_tui.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Config Step Layout ───────────────────────────────────────────────────────

function view_config_step(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    # Outer border
    outer = Block(
        title = phase_title(m),
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)
    inner.width < 20 && return

    # Layout: BigText title | progress + content | hints
    rows = tsplit(Layout(Vertical, [Fixed(7), Fill(), Fixed(1)]), inner)
    length(rows) < 3 && return

    # BigText step title
    title_text = step_title_text(m)
    bt = BigText(title_text; style = tstyle(:accent, bold = true))
    bt_w, _ = intrinsic_size(bt)
    bt_area =
        Rect(rows[1].x + 1, rows[1].y, min(bt_w, rows[1].width), min(5, rows[1].height))
    render(bt, bt_area, buf)

    # Content area split: progress list | step content
    content_area = rows[2]
    cols = tsplit(Layout(Horizontal, [Fixed(22), Fill()]), content_area)
    length(cols) < 2 && return

    # Progress list (left sidebar)
    view_progress_list(m, cols[1], buf)

    # Step content (right side)
    step_area = cols[2]

    # Neuromancer: subtle rain background during config
    if m.mode == L33T
        render_dim_rain(m, step_area, buf)
    end

    if m.phase == PHASE_SECURITY_MODE
        view_security_mode_step(m, step_area, buf)
    elseif m.phase == PHASE_PORT
        view_port_step(m, step_area, buf)
    elseif m.phase == PHASE_API_KEY_GEN
        view_api_key_step(m, step_area, buf)
    elseif m.phase == PHASE_QUICK_OR_ADV
        view_quick_or_adv_step(m, step_area, buf)
    elseif m.phase == PHASE_IP_ALLOWLIST
        view_ip_allowlist_step(m, step_area, buf)
    elseif m.phase == PHASE_INDEX_DIRS
        view_index_dirs_step(m, step_area, buf)
    elseif m.phase == PHASE_SUMMARY
        view_summary_step(m, step_area, buf)
    elseif m.phase == PHASE_GATE
        view_gate_step(m, step_area, buf)
    elseif m.phase == PHASE_SAVING
        view_saving_step(m, step_area, buf)
    end

    # Companion art in bottom-right of step area
    render_companion_art(m, step_area, buf)

    # Hint bar
    hints = step_hints(m)
    set_string!(buf, rows[3].x + 1, rows[3].y, hints, tstyle(:text_dim))
end

# ── Progress List ────────────────────────────────────────────────────────────

function phase_to_step_index(phase::WizardPhase)
    phase == PHASE_SECURITY_MODE && return 1
    phase == PHASE_PORT && return 2
    phase == PHASE_API_KEY_GEN && return 3
    phase == PHASE_QUICK_OR_ADV && return 4
    phase == PHASE_IP_ALLOWLIST && return 5
    phase == PHASE_INDEX_DIRS && return 6
    phase == PHASE_SUMMARY && return 7
    phase == PHASE_GATE && return 8
    phase == PHASE_SAVING && return 9
    return 0
end

function view_progress_list(m::SetupWizardModel, area::Rect, buf::Buffer)
    current_step = phase_to_step_index(m.phase)

    steps =
        m.advanced ?
        [
            "Security Mode",
            "Port",
            "API Key",
            "Quick/Advanced",
            "IP Allowlist",
            "Index Dirs",
            "Summary",
            "Auto-connect",
            "Save",
        ] : ["Security Mode", "Port", "API Key", "Quick/Advanced", "Auto-connect", "Save"]

    items = ProgressItem[]
    for (i, label) in enumerate(steps)
        real_step = m.advanced ? i : (i <= 4 ? i : (i == 5 ? 8 : 9))
        status = if real_step < current_step
            task_done
        elseif real_step == current_step
            task_running
        else
            task_pending
        end
        push!(items, ProgressItem(label; status = status))
    end

    blk = Block(
        title = "Steps",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    blk_inner = render(blk, area, buf)

    pl = ProgressList(items; tick = m.tick)
    render(pl, blk_inner, buf)
end

# ── Step Content Views ───────────────────────────────────────────────────────

function view_security_mode_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    flavor = mode_flavor_text(m)

    options = [
        ("STRICT", flavor[:strict], ":strict - API key + IP allowlist"),
        ("RELAXED", flavor[:relaxed], ":relaxed - API key, any IP"),
        ("LAX", flavor[:lax], ":lax - Localhost only, no key"),
    ]

    for (i, (name, desc, detail)) in enumerate(options)
        row_y = y + (i - 1) * 3
        row_y + 1 > bottom(area) && break

        is_sel = i == m.sec_mode_selected
        marker = is_sel ? ">" : " "
        name_style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        desc_style = is_sel ? tstyle(:text) : tstyle(:text_dim)

        set_string!(buf, area.x + 1, row_y, "$marker $name", name_style)
        set_string!(buf, area.x + 4, row_y + 1, desc, desc_style)
        set_string!(buf, area.x + 4, row_y + 2, detail, tstyle(:text_dim, dim = true))
    end
end

function view_gate_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    flavor = mode_flavor_text(m)
    y = area.y + 1

    # Themed tagline
    set_string!(buf, area.x + 1, y, flavor[:gate_tagline], tstyle(:accent, bold = true))
    y += 2

    # Plain-language explanation of what "auto-connect" actually does
    for line in (
        "Every Julia session you start will show up in the",
        "Kaimon dashboard automatically — your AI tools can",
        "reach it with no per-session setup.",
    )
        set_string!(buf, area.x + 1, y, line, tstyle(:text))
        y += 1
    end
    y += 1

    # The exact footprint (and that it's reversible)
    set_string!(
        buf,
        area.x + 1,
        y,
        "It adds KaimonGate to your global environment and a",
        tstyle(:text_dim),
    )
    y += 1
    set_string!(
        buf,
        area.x + 1,
        y,
        "small auto-connect block to startup.jl. Undo anytime.",
        tstyle(:text_dim),
    )
    y += 2

    options = [
        ("YES", flavor[:gate_yes]),
        ("NOT NOW", flavor[:gate_no]),
        ("NEVER", flavor[:gate_never]),
    ]
    for (i, (name, desc)) in enumerate(options)
        row_y = y + (i - 1) * 2
        row_y > bottom(area) && break

        is_sel = i == m.gate_selected
        marker = is_sel ? ">" : " "
        name_style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        desc_style = is_sel ? tstyle(:text) : tstyle(:text_dim)

        set_string!(buf, area.x + 1, row_y, "$marker $name", name_style)
        set_string!(buf, area.x + 12, row_y, desc, desc_style)
    end
end

function view_port_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Server port (1024-65535):", tstyle(:text))

    ti_area = Rect(area.x + 1, y + 2, min(30, area.width - 2), 1)
    render(m.port_input, ti_area, buf)

    set_string!(buf, area.x + 1, y + 4, "Default: 2828", tstyle(:text_dim))
end

function view_api_key_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    flavor = mode_flavor_text(m)

    set_string!(buf, area.x + 1, y, flavor[:api_key], tstyle(:text))
    y += 2

    if m.sec_mode == :lax
        set_string!(buf, area.x + 1, y, "No API key needed in lax mode.", tstyle(:text_dim))
        set_string!(buf, area.x + 1, y + 2, "Press Enter to continue.", tstyle(:text))
    else
        set_string!(buf, area.x + 1, y, "Generated API key:", tstyle(:text))
        y += 1

        # Display key with accent color (truncate if needed)
        key_display =
            length(m.api_key) > area.width - 4 ? m.api_key[1:area.width-7] * "..." :
            m.api_key
        set_string!(buf, area.x + 2, y, key_display, tstyle(:warning, bold = true))
        y += 2

        if m.api_key_copied
            set_string!(
                buf,
                area.x + 1,
                y,
                "Copied to clipboard!",
                tstyle(:success, bold = true),
            )
        else
            set_string!(
                buf,
                area.x + 1,
                y,
                "Press [c] to copy to clipboard",
                tstyle(:text_dim),
            )
        end
        y += 2
        set_string!(buf, area.x + 1, y, "Press Enter to continue", tstyle(:text))
    end
end

function view_quick_or_adv_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(
        buf,
        area.x + 1,
        y,
        "Configuration complete!",
        tstyle(:success, bold = true),
    )
    y += 2
    set_string!(buf, area.x + 1, y, "Press Enter to save with defaults:", tstyle(:text))
    y += 1
    set_string!(buf, area.x + 3, y, "IPs: 127.0.0.1, ::1", tstyle(:text_dim))
    y += 1
    set_string!(buf, area.x + 3, y, "Index: default extensions", tstyle(:text_dim))
    y += 2
    set_string!(buf, area.x + 1, y, "Press [a] for advanced settings:", tstyle(:text))
    y += 1
    set_string!(buf, area.x + 3, y, "Customize IPs, index directories", tstyle(:text_dim))
end

function view_ip_allowlist_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "IP Allowlist:", tstyle(:text, bold = true))
    y += 1

    # Show existing IPs
    for (i, ip) in enumerate(m.allowed_ips)
        row_y = y + i - 1
        row_y > bottom(area) - 5 && break
        is_sel = i == m.ip_list_selected
        marker = is_sel ? ">" : " "
        style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        protected = (ip == "127.0.0.1" || ip == "::1") ? " (locked)" : ""
        set_string!(buf, area.x + 1, row_y, "$marker $ip$protected", style)
    end

    # Input field at bottom
    input_y = y + length(m.allowed_ips) + 1
    set_string!(buf, area.x + 1, input_y, "Add IP (empty to continue):", tstyle(:text_dim))
    ti_area = Rect(area.x + 1, input_y + 1, min(30, area.width - 2), 1)
    render(m.ip_input, ti_area, buf)
end

function view_index_dirs_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Index Directories:", tstyle(:text, bold = true))
    y += 1

    if isempty(m.index_dirs)
        set_string!(buf, area.x + 3, y, "(default: src/)", tstyle(:text_dim))
        y += 1
    else
        for (i, dir) in enumerate(m.index_dirs)
            row_y = y + i - 1
            row_y > bottom(area) - 5 && break
            is_sel = i == m.index_list_selected
            marker = is_sel ? ">" : " "
            style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
            set_string!(buf, area.x + 1, row_y, "$marker $dir", style)
        end
        y += length(m.index_dirs)
    end

    input_y = y + 1
    set_string!(
        buf,
        area.x + 1,
        input_y,
        "Add directory (empty to continue):",
        tstyle(:text_dim),
    )
    ti_area = Rect(area.x + 1, input_y + 1, min(40, area.width - 2), 1)
    render(m.index_input, ti_area, buf)
end

function view_summary_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Configuration Summary", tstyle(:text, bold = true))
    y += 2

    items = [
        ("Mode", string(m.sec_mode)),
        ("Port", string(m.port)),
        (
            "API Key",
            m.sec_mode == :lax ? "(none)" : m.api_key[1:min(20, length(m.api_key))] * "...",
        ),
        ("IPs", join(m.allowed_ips, ", ")),
        ("Index Dirs", isempty(m.index_dirs) ? "(default)" : join(m.index_dirs, ", ")),
    ]

    for (label, val_str) in items
        y > bottom(area) - 4 && break
        set_string!(buf, area.x + 2, y, "$label:", tstyle(:text_dim))
        set_string!(buf, area.x + 16, y, val_str, tstyle(:text))
        y += 1
    end

    y += 2
    # Confirm / Cancel buttons
    confirm_style =
        m.summary_selected == :confirm ? tstyle(:success, bold = true) : tstyle(:text_dim)
    cancel_style =
        m.summary_selected == :cancel ? tstyle(:error, bold = true) : tstyle(:text_dim)

    set_string!(buf, area.x + 5, y, "[ Confirm ]", confirm_style)
    set_string!(buf, area.x + 20, y, "[ Cancel ]", cancel_style)
end

function view_saving_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + area.height ÷ 2 - 2

    set_string!(buf, area.x + 2, y, "Saving configuration...", tstyle(:text))
    y += 2

    gauge_area = Rect(area.x + 2, y, min(area.width - 4, 50), 1)
    g = Gauge(
        m.save_progress;
        filled_style = tstyle(:accent),
        empty_style = tstyle(:text_dim, dim = true),
        label_style = tstyle(:text_bright, bold = true),
    )
    render(g, gauge_area, buf)

    if m.save_done
        y += 2
        if m.save_success
            set_string!(buf, area.x + 2, y, "Config saved!", tstyle(:success, bold = true))
        else
            set_string!(buf, area.x + 2, y, m.save_message, tstyle(:error))
        end
    end
end

function view_done(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    outer = Block(
        title = "COMPLETE",
        border_style = tstyle(:success, bold = true),
        title_style = tstyle(:success, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)

    # BigText "DONE"
    bt = BigText("DONE"; style = tstyle(:success, bold = true))
    bt_w, _ = intrinsic_size(bt)
    bt_area = center(inner, min(bt_w, inner.width), 5)
    bt_area = Rect(bt_area.x, inner.y + 2, bt_area.width, 5)
    render(bt, bt_area, buf)

    y = inner.y + 9

    if m.save_success
        msg =
            m.mode == STANDARD ? "The castle defenses are set!" :
            m.mode == GENTLE ? "Your workspace is safe and sound!" :
            "ICE deployed. You're in the clear, cowboy."
        set_string!(
            buf,
            inner.x + (inner.width - length(msg)) ÷ 2,
            y,
            msg,
            tstyle(:accent, bold = true),
        )
        y += 2

        path = get_global_config_path()
        path_msg = "Config: $path"
        set_string!(
            buf,
            inner.x + max(1, (inner.width - length(path_msg)) ÷ 2),
            y,
            path_msg,
            tstyle(:text_dim),
        )
        y += 2

        if m.sec_mode != :lax && !isempty(m.api_key)
            key_msg = "API Key: $(m.api_key[1:min(20, length(m.api_key))])..."
            set_string!(
                buf,
                inner.x + max(1, (inner.width - length(key_msg)) ÷ 2),
                y,
                key_msg,
                tstyle(:warning),
            )
        end
    else
        set_string!(buf, inner.x + 3, y, "Save failed: $(m.save_message)", tstyle(:error))
    end

    y = bottom(inner) - 1
    set_string!(
        buf,
        inner.x + (inner.width - 28) ÷ 2,
        y,
        " Press any key to exit... ",
        tstyle(:text_dim),
    )
end

