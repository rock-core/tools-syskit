function createGraphLinks(graph_type) {
    $(`.method_details_list .${graph_type}-graph`).
        before(`<span class='showGraph'>[<a href='#' class='toggleGraph-${graph_type}'>View ${graph_type}</a>]</span>`);
    $(`.toggleGraph-${graph_type}`).toggle(function() {
       $(this).parent().nextAll(`.${graph_type}-graph`).slideDown(100);
       $(this).text(`Hide ${graph_type}`);
    },
    function() {
        $(this).parent().nextAll(`.${graph_type}-graph`).slideUp(100);
        $(this).text(`View ${graph_type}`);
    });
}

$(document).ready(function() {
  createGraphLinks("hierarchy");
  createGraphLinks("dataflow");
})