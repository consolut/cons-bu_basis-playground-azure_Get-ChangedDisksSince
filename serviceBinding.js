function initModel() {
	var sUrl = "/sap/opu/odata/sap/Z_C_TIMESHEETANALYSIS_CDS/";
	var oModel = new sap.ui.model.odata.ODataModel(sUrl, true);
	sap.ui.getCore().setModel(oModel);
}