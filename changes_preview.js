(function () {
	/**
	 * Check if the UI5 version is sufficient to use Preview connectors instead of fake connectors
	 *
	 * @returns {boolean} True, if version is sufficient
	 */
	function usePreviewConnector() {
		var aVersionSplit = sap.ui.getVersionInfo().version.split(/[.-]/);
		var iMinorVersion = parseInt(aVersionSplit[1]);

		return iMinorVersion > 72;
	}

	/**
	 * Loads the changes for the given component class name from the workspace
	 *
	 * @returns {Promise<Object>} Returns a Promise with the changes and componentClassName
	 */
	function loadChanges() {
		var oResult = {
			"changes": [],
			"settings": {
				"isKeyUser": true,
				"isAtoAvailable": false,
				"isProductiveSystem": false
			}
		};

		function prepareChanges() {
			var oChanges = {};

			if (usePreviewConnector()) {
				oResult.changes.forEach(function (change) {
					var sKey = "sap.ui.fl." + change.fileName;
					oChanges[sKey] = change;
				});
			} else {
				oChanges = {
					changes: oResult,
					componentClassName: "cons.consolutTimesheetAnalysis"
				};
			}

			return oChanges;
		}

		//Get the content of the changes folder.
		var aPromises = [];
		var sCacheBusterFilePath = "/sap-ui-cachebuster-info.json";

		/*eslint-disable promise/avoid-new*/
		/*eslint-disable promise/catch-or-return*/
		/*eslint-disable promise/always-return*/
		/*eslint-disable promise/no-nesting*/
		/*eslint-disable consistent-return*/
		/*eslint-disable xss/no-mixed-html*/
		return new Promise(function (resolve, reject) {
			$.ajax({
				url: window.location.origin + sCacheBusterFilePath,
				type: "GET",
				cache: false
			}).then(function (oCachebusterContent) {

				function isValidChangeFileExt(sPath) {
					return [".change", ".ctrl_variant", ".ctrl_variant_change", "ctrl_variant_management_change"].some(function (sFileType) {
						return sPath.endsWith(sFileType);
					});
				}

				function isNonMTAChange(sPath) {
					return sPath.indexOf("webapp/changes/") === 0 && isValidChangeFileExt(sPath)
				}

				function isMTAChange(sPath) {
					// For MTA projects we need to take only changes which are relevant for the current HTML5 module.
					// The paths in sap-ui-cachebuster-info.json for MTA don't start with "webapp/changes".
					// Instead, they start with  <MTA-HTML5-MODULE-NAME>, e.g. <MTA-HTML5-MODULE-NAME>/webapp/changes/<change-file>
					return sPath.startsWith("consolutTimesheetAnalysis") && sPath.indexOf("webapp/changes/") > 0 && isValidChangeFileExt(sPath);
				}

				//we are looking for only change files
				var aChangeFilesPaths = Object.keys(oCachebusterContent).filter(function (sPath) {
					return isNonMTAChange(sPath) || isMTAChange(sPath);
				});

				$.each(aChangeFilesPaths, function (index, sFilePath) {
					var sChangesRelativePathIndex = sFilePath.indexOf("webapp/changes");
					sFilePath = sFilePath.slice(sChangesRelativePathIndex);
					/*eslint-disable no-param-reassign*/
					aPromises.push(
						$.ajax({
							url: window.location.origin + "/" + sFilePath,
							type: "GET",
							cache: false
						}).then(function (sChangeContent) {
							return JSON.parse(sChangeContent);
						})
					);
				});
			}).always(function () {
				return Promise.all(aPromises).then(function (aChanges) {
					var aChangePromises = [],
						aProcessedChanges = [];
					aChanges.forEach(function (oChange) {
						var sChangeType = oChange.changeType;
						if (sChangeType === "addXML" || sChangeType === "codeExt") {
							/*eslint-disable no-nested-ternary*/
							var sPath = sChangeType === "addXML" ? oChange.content.fragmentPath : sChangeType === "codeExt" ? oChange.content.codeRef :
								"";
							var sWebappPath = sPath.match(/webapp(.*)/);
							var sUrl = "/" + sWebappPath[0];
							aChangePromises.push(
								$.ajax({
									url: sUrl,
									type: "GET",
									cache: false
								}).then(function (oFileDocument) {
									if (sChangeType === "addXML") {
										oChange.content.fragment = FakeLrepConnector.prototype.stringToAscii(oFileDocument.documentElement.outerHTML);
										oChange.content.selectedFragmentContent = oFileDocument.documentElement.outerHTML;
									} else if (sChangeType === "codeExt") {
										oChange.content.code = FakeLrepConnector.prototype.stringToAscii(oFileDocument);
										oChange.content.extensionControllerContent = oFileDocument;
									}
									return oChange;
								})
							);
						} else {
							aProcessedChanges.push(oChange);
						}
					});
					// aChanges holds the content of all change files from the project (empty array if no such files)
					// sort the array by the creation timestamp of the changes
					if (aChangePromises.length > 0) {
						return Promise.all(aChangePromises).then(function (aUpdatedChanges) {
							aUpdatedChanges.forEach(function (oChange) {
								aProcessedChanges.push(oChange);
							});
							aProcessedChanges.sort(function (change1, change2) {
								return new Date(change1.creation) - new Date(change2.creation);
							});
							oResult.changes = aProcessedChanges;
							resolve(prepareChanges());
						});
					} else {
						aProcessedChanges.sort(function (change1, change2) {
							return new Date(change1.creation) - new Date(change2.creation);
						});
						oResult.changes = aProcessedChanges;
						resolve(prepareChanges());
					}
				});
			});
		});
	}

	if (usePreviewConnector()) {
		/********************************************************************************************************************************
		 *												New Preview Connector															*
		 ********************************************************************************************************************************/
		sap.ui.define("PreviewConnector", [
			"sap/base/util/merge",
			"sap/ui/fl/apply/_internal/connectors/ObjectStorageConnector"
		], function (
			merge,
			ObjectStorageConnector
		) {
			"use strict";

			var PreviewConnector = merge({}, ObjectStorageConnector, {
				oStorage: {
					_itemsStoredAsObjects: true,
					getItems: loadChanges
				}
			});

			return PreviewConnector;
		}, true);
	} else {
		/******************************************************************************************************************************
		 *												Fake LREP Connector															  *
		 ******************************************************************************************************************************/
		//This file used only for loading the changes in the webide preview and not required to be checked in.
		//Load the fake lrep connector
		sap.ui.getCore().loadLibraries(["sap/ui/fl"]);
		sap.ui.require(["sap/ui/fl/FakeLrepConnector"], function (FakeLrepConnector) {
			jQuery.extend(FakeLrepConnector.prototype, {
				create: function (oChange) {
					return Promise.resolve();
				},
				stringToAscii: function (sCodeAsString) {
					if (!sCodeAsString || sCodeAsString.length === 0) {
						return "";
					}
					var sAsciiString = "";
					for (var i = 0; i < sCodeAsString.length; i++) {
						sAsciiString += sCodeAsString.charCodeAt(i) + ",";
					}
					if (sAsciiString !== null && sAsciiString.length > 0 && sAsciiString.charAt(sAsciiString.length - 1) === ",") {
						sAsciiString = sAsciiString.substring(0, sAsciiString.length - 1);
					}
					return sAsciiString;
				},
				/*
				 * Get the content of the sap-ui-cachebuster-info.json file
				 * to get the paths to the changes files
				 * and get their content
				 */
				loadChanges: loadChanges
			});
			FakeLrepConnector.enableFakeConnector();
		});
	}
})();