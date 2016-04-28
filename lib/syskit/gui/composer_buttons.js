function addComposerButtons(list_div) {
    btn = document.createElement("a");
    btn.setAttribute("class", "composer_buttons");
    btn.setAttribute("href", "link://compose?id=" + list_div.getAttribute("object_id"));
    text = document.createTextNode("Add to Composer");
    btn.appendChild(text);

    list_div.appendChild(btn);
}
function removeComposerButtons(list_div) {
    children = list_div.children;
    for(i = 0; i < children.length; ++i)
    {
        child = children[i];
        if (child.getAttribute("class") == "composer_buttons")
            list_div.removeChild(child);
    }
}
