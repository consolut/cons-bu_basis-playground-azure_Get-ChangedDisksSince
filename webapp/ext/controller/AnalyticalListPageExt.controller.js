sap.ui.define([
    "sap/ui/model/Filter", 
    "sap/ui/comp/smartfilterbar/SmartFilterBar", 
    "sap/m/Input"
], function (Filter, SmartFilterBar, Input) {
    "use strict";
    return {
        oSmartTable: null,

    onInit: function (oEVent) {
        this.oSmartTable = this.getView().byId("cons.consolutTimesheetAnalysis::sap.suite.ui.generic.template.AnalyticalListPage.view.AnalyticalListPage::Z_C_TIMESHEETANALYSIS--table");
        this.oSmartTable.setUseExportToExcel(true);

        this.oI18nModel = this.getOwnerComponent().getModel("@i18n");
    },

    modifyStartupExtension: function (oStartupObject) {
        const oSelectionVariant = oStartupObject.selectionVariant;

        let oSelOptCalendarYear = oSelectionVariant.getSelectOption("CalendarYear");

        if (oSelOptCalendarYear) {
            const aYears = oSelOptCalendarYear[0].Low.split("-");

            if (aYears.length === 2) {
                oSelectionVariant.removeSelectOption("CalendarYear");
                oSelectionVariant.addSelectOption("CalendarYear", "I", "BT", aYears[0], aYears[1]);
            }
        }
    },

    onInitSmartFilterBarExtension: function (oEvent) {
        var oFilterButton = this.getView().byId(
            "cons.consolutTimesheetAnalysis::sap.suite.ui.generic.template.AnalyticalListPage.view.AnalyticalListPage::Z_C_TIMESHEETANALYSIS--template::VisualFilterDialogButton"
        );
        oFilterButton.setVisible(false);

        var oSmartFilterBar = oEvent.getSource();
        var oCalendarMonthFilterItem = oSmartFilterBar._getFilterItemByName("CalendarMonth");
        oCalendarMonthFilterItem.setVisibleInFilterBar(false);
        //set default value to current year
        if(!oSmartFilterBar._getFilterItemByName("CalendarYear").getControl().getValue()) oSmartFilterBar._getFilterItemByName("CalendarYear").getControl().setValue(new Date().getFullYear())

        oEvent.getSource()._oSearchButton.firePress();

        var oEditBtn = this.getView().byId("ActionEditBtn");
        oEditBtn.setTooltip(this.oI18nModel.getResourceBundle().getText("EDITBTN_TOOLTIP"));
    },
    onAfterRendering: function (oEvent) {
        var oSmartChart = this.getView().byId("cons.consolutTimesheetAnalysis::sap.suite.ui.generic.template.AnalyticalListPage.view.AnalyticalListPage::Z_C_TIMESHEETANALYSIS--chart")
        oSmartChart.attachInitialized(async function (oControlEvent) {
            let InnerChart = oSmartChart.getChartAsync().then(function (oInnerChart) {
                oInnerChart.setVizProperties({ general: { showAsUTC: false } });
            });
        }, this);
    },

    onMassChangeRecords: function () {
        var oTable = this.oSmartTable.getTable(),
            aSelectedIndices = oTable._oSelectionPlugin.getSelectedIndices(),
            aTimeRecordOrigins = [],
            oContext = oTable.getContextByIndex(aSelectedIndices[0]),
            sRecord = oContext.getObject();

        if (!sRecord.TimeSheetRecord) {
            sap.m.MessageBox.warning(this.oI18nModel.getResourceBundle().getText("ID_REQUIRED_MSG"));
            return;
        }

        aSelectedIndices.forEach(function (iIndex) {
            var oContext = oTable.getContextByIndex(iIndex);
            aTimeRecordOrigins.push(oContext.getObject().TimeSheetRecord);
        });

        var oCrossAppNavigator = sap.ushell.Container.getService("CrossApplicationNavigation");

            oCrossAppNavigator.toExternal({
                target: {
                    semanticObject: "MassChanges",
                    action: "change"
                },
                params: {
                    "TimeSheetRecord": aTimeRecordOrigins
                }
            });

    },

    getCustomAppStateDataExtension: function (oCustomData) {
        //the content of the custom field will be stored in the app state, so that it can be restored later, for example after a back navigation.
        //The developer has to ensure that the content of the field is stored in the object that is passed to this method.
        if (oCustomData) {
            var oCustomField1 = this.oView.byId("Id_CalendarYear");
            if (oCustomField1) {
                oCustomData.CalendarYear = oCustomField1.getValue();
            }
        }
    },
    restoreCustomAppStateDataExtension: function (oCustomData) {
        //in order to restore the content of the custom field in the filter bar, for example after a back navigation,
        //an object with the content is handed over to this method. Now the developer has to ensure that the content of the custom filter is set to the control
        if (oCustomData) {
            if (oCustomData.CalendarYear) {
                var oComboBox = this.oView.byId("Id_CalendarYear");
                oComboBox.setValue(oCustomData.CalendarYear);
            }
        }
    },

    onBeforeRebindChartExtension(oEvent){
        var oBindingParams = oEvent.getParameter("bindingParams");
        oBindingParams.parameters = oBindingParams.parameters || {};

        var oSmartChart = oEvent.getSource();
        var oSmartFilterBar = this.byId(oSmartChart.getSmartFilterId());
        this._handleCalendarYearFilter(oSmartFilterBar, oBindingParams.filters);
    },

    onBeforeRebindTableExtension: function(oEvent) {
        var oBindingParams = oEvent.getParameter("bindingParams");
        oBindingParams.parameters = oBindingParams.parameters || {};

        var oSmartTable = oEvent.getSource();
        var oSmartFilterBar = this.byId(oSmartTable.getSmartFilterId());
        this._handleCalendarYearFilter(oSmartFilterBar, oBindingParams.filters);
    
    },

    /**
     * Will extend the filter by handeling the value passed in custom filter field 'Calendar Year'
     * @param {sap.ui.comp.smartfilterbar.SmartFilterBar} oSmartFilterBar - Smart Filter bar
     * @param {sap.ui.model.Filter} aFilter - Filter object  
     * @returns {sap.ui.model.Filter} Adapted Filter object
     */
    _handleCalendarYearFilter(oSmartFilterBar, aFilter){
        if (oSmartFilterBar instanceof SmartFilterBar) {
            var oCalendarYearControl = oSmartFilterBar.getControlByKey("CalendarYear");
            if (oCalendarYearControl instanceof Input) {
                let sCalendarYear = oCalendarYearControl.getValue();
                if(!this._checkCalendarYear(sCalendarYear)){
                    oCalendarYearControl.setValueState("Error");
                    oCalendarYearControl.setValueStateText(this.oI18nModel.getResourceBundle().getText("errorCalendarYear"))
                    //prevents sending an request to the backend! DO NOT catch! Otherwise request will be sent!
                    throw Error("Invald Year!");
                }
                if(oCalendarYearControl.getValue().includes("-")){
                    let aCalendarYears = sCalendarYear.split("-");
                    aFilter.push(new Filter("CalendarYear", "BT", aCalendarYears[0], aCalendarYears[1]));
                }else{
                    //single year
                    aFilter.push(new Filter("CalendarYear", "EQ", oCalendarYearControl.getValue()));
                }
            }
            return aFilter;
        }
    },

    /**
     * Resets value state of filter field Calendar Year if its currently set to 'Error'. Used in event liveChnage of input field
     * @param {sap.ui.base.Event} oEvent 
     */
    onLiveChangeCalendarYear(oEvent){
        if(oEvent.getSource().getValueState() === "Error") oEvent.getSource().setValueState("None")
    },
    
    /**
     * Will check whether the given calendar year suits following formats:
     *  XXXX
     *  XXXX-XXXX
     *  XXXX -XXXX
     *  XXXX- XXXX
     *  XXXX - XXXXX
     * Will also check wether the second date is greater than the first date, when using date ranges
     * @param {String} sCalendarYear - Given calendar year
     * @returns {Boolean} ture if given calendar year is valid, false if not
     */
    _checkCalendarYear(sCalendarYear){
        if(sCalendarYear.includes("-")){
            //match sting patterns XXXX-XXXX, XXXX - XXXX, XXXX- XXXX, XXXX -XXXX (range 1000-9999)
            let aMatches = sCalendarYear.match(/[1-9]\d{3}\s[-]\s[1-9]\d{3}|[1-9]\d{3}[-][1-9]\d{3}|[1-9]\d{3}[-]\s[1-9]\d{3}|[1-9]\d{3}\s[-][1-9]\d{3}/g);
            if(!aMatches) return false;
            let aCalendarYears = sCalendarYear.split("-")
            if(parseInt(aCalendarYears[0]) > parseInt(aCalendarYears[1])) return false;
            return true;
        }
        //Match string pattern XXXX (range 1000-9999)
        return  sCalendarYear.match(/[1-9]\d{3}/g) === null ? false : true;
    },

    _getDateFormatted: function (sDate) {
        var sYear = sDate.substring(0, 4),
            sMonth = sDate.substring(4, 6),
            sDay = sDate.substring(6, 8);

        return sYear + "-" + sMonth + "-" + sDay;
    }

    }
});