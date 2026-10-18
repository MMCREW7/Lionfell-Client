-- Lionfell theme: imports the shared Lf* styles and restyles MiniWindow so every
-- floating HUD panel uses the same flat 9-slice skin from data/images/lionfell.

function init()
    g_ui.importStyle('styles/lionfell')
    g_ui.importStyle('styles/miniwindow')
    g_ui.importStyle('styles/game')
end

function terminate()
end
