/**
 * `i18n/additions` - the keys A3.4's redesign introduced, plus every key the previous dashboard referenced but
 * never defined.
 *
 * ## Why these were missing at all
 *
 * `t()` accepts any string, so a key that does not exist is not a type error - i18next renders the key itself.
 * Two dashboard cards shipped reading the literal text `dashboard.completionRateHint`. Nothing caught it:
 * not `tsc`, not lint, not the other tests. `tests/i18n-catalogue.test.ts` now scans every `t("...")` in the
 * source and fails when a key is absent from either catalogue, so this file cannot go stale the same way.
 *
 * ## Why the additions are merged here rather than appended inline
 *
 * The catalogues are JSON and cannot be spread. Keeping the new keys in one reviewable block - each with the
 * reason it exists - makes the next audit a read rather than a diff against a generated file.
 *
 * ## Copy rules, applied throughout
 *
 * - **Say what is wrong, not what is zero.** `activeEmpty` says the day is quiet; it does not print "0 orders".
 * - **Name the unit.** A bare number for a duration is a figure nobody can act on.
 * - **A caveat travels with the number.** Rates carry their hint in the same definition-list row.
 * - **No database vocabulary.** No "status", "unpaid" as a bare label, or column names. "Cash not collected" is
 *   what an operator needs to read; `payment_status = 'unpaid'` is what caused it.
 */

export const enAdditions = {
  /**
   * Keys referenced by existing screens but never defined. These rendered as their own names on screen - the
   * bug `tests/i18n-catalogue.test.ts` was written to stop recurring.
   */
  errors: {
    /**
     * The soft-delete and restore trio. Each names a *state* rather than repeating "Something went wrong" -
     * in every case the operator already knows what they did and needs to know what the record is now, and
     * `alreadyDeleted` used to surface as the generic message after an operator clicked Delete twice.
     */
    reasonRequired: "Give a reason. It is recorded against this change and shown in the audit trail.",
    alreadyDeleted: "This record is already deleted.",
    notDeleted: "This record is not deleted, so there is nothing to restore.",
    /**
     * Written for an engineer, on purpose.
     *
     * `KEY_REQUIRED` fires when `p_id` arrives null, which in practice means the call omitted its named
     * arguments and PostgREST could not route it. An operator cannot act on that, so the message hands it over
     * and names the code - the same shape as the existing `unknownCode`.
     */
    keyRequired: "This action was refused (KEY_REQUIRED). Tell an engineer the code in brackets.",

    /** The profile's 404 result. */
    notFoundHint: "It may have been deleted, or the link is out of date.",
  },

  /** Column headers the vendor list adds to the shared `common` block. */
  common: {
    rating: "Rating",
    createdAt: "Joined",
  },

  /** A4.1 - A4.3: the vendor list, the edit form, and the delete/restore dialogs. */
  vendor: {
    /** The form's and the dialogs' escape hatch. */
    cancel: "Cancel",
    title: "Merchants",
    searchPlaceholder: "Search by name",
    filterVertical: "Type",
    filterApproved: "Approval",
    filterState: "Showing",
    stateActive: "Live only",
    stateDeleted: "Deleted only",
    stateAll: "Live and deleted",
    approvedAll: "Any",
    approvedYes: "Approved",
    approvedNo: "Not approved",
    verticalAll: "All types",
    verticalFood: "Food",
    verticalGrocery: "Grocery",
    verticalPharmacy: "Pharmacy",
    verticalFlowers: "Flowers",
    verticalBakery: "Bakery",
    verticalOthers: "Other",

    add: "Add merchant",
    edit: "Edit merchant",
    open: "Open",
    delete: "Delete",
    restore: "Restore",

    empty: "No merchants match these filters.",
    emptyHint: "Try a different search, or widen the filters.",
    showingRange: "{{from}}–{{to}} of {{total}}",
    previous: "Previous",
    next: "Next",
    pageOf: "Page {{page}} of {{pages}}",

    // Field labels. Each key matches the RPC whitelist exactly: `vendor.slug` is the `slug` column.
    slug: "URL slug",
    slugHint: "Lowercase letters, numbers and dashes. Used in links.",
    name: "Name (English)",
    nameAr: "Name (Arabic)",
    legalName: "Legal name",
    brand: "Brand",
    verticalType: "Type",
    city: "City",
    area: "Area",
    latitude: "Latitude",
    longitude: "Longitude",
    geohash: "Geohash prefix",
    geohashHint: "Short code for this location. Used to group nearby searches.",
    deliveryRadius: "Delivery radius (km)",
    isOpen: "Open now",
    isBusy: "Marked busy",
    autoOpen: "Opens automatically",
    isApproved: "Approved",
    isActive: "Active",
    capacityPerSlot: "Orders per slot",
    rejectRate: "Rejection rate",
    deliveryFeeOverride: "Delivery fee override",
    minimumOrderValue: "Minimum order value",
    prepTimeMin: "Prep time (min)",
    prepTimeMax: "Prep time (max)",
    logoPath: "Logo path",
    description: "Description (English)",
    descriptionAr: "Description (Arabic)",
    contactPhone: "Phone",
    contactLandline: "Landline",

    /**
     * Group headings. The form has 28 fields; ungrouped it is a wall of inputs and nobody finds the one they
     * came for. The order follows how a merchant is actually set up: name it, place it, set how it operates,
     * how it is reached, then its numbers.
     */
    groupIdentity: "Identity",
    groupLocation: "Location",
    groupOperations: "Operations",
    groupContact: "Contact",
    groupPricing: "Numbers",

    createTitle: "New merchant",
    editTitle: "Edit {{name}}",
    requiredOnCreate: "Required to create a merchant.",
    noChange: "Nothing has changed yet.",
    clear: "Clear",

    /**
     * Delete and restore. Both quote what will actually happen, because the two differ in a way an operator
     * would otherwise get wrong: restoring puts `is_active` back but deliberately leaves `is_approved` alone,
     * so a restored merchant is still invisible in the app until it is separately approved.
     */
    deleteTitle: "Delete {{name}}?",
    deleteBody:
      "This hides the merchant from the app straight away. Their orders are kept. The reason below is recorded with your name.",
    restoreTitle: "Restore {{name}}?",
    restoreBody:
      "The merchant becomes active again but stays unapproved, so it will not appear in the app until you approve it.",
    reasonLabel: "Reason",
    reasonPlaceholder: "Why is this changing?",
    reasonHint: "Recorded against this change. Be specific - it is the first thing anyone reads later.",
    deletedOn: "Deleted",
  },

  status: {
    /**
     * Reconciliation outcome. Distinct words rather than a shared "OK": an operator reading this needs to know
     * whether cash accounted for or did not, and "Balanced" answers that in one word.
     */
    balanced: "Balanced",
    unbalanced: "Does not reconcile",
  },
  /** The work queue at the top of the console. */
  attention: {
    title: "Needs attention",
    clearTitle: "All clear",
    // Reads as a state, not as a sentence about cash. The earlier "cash accounts for" named a float an
    // operator has to translate, and this line is read at a glance in the first two seconds of a shift.
    clearBody: "No late orders, no unaccepted orders, no unreconciled cash.",
    varianceTitle: "Cash does not reconcile",
    varianceDetail: "{{amount}} {{currency}} unexplained on {{date}}. Open reconciliation to record why.",
    lateOrder: "Order {{number}} is late",
    lateOrderDetail: "{{minutes}} min past its promise · {{amount}} {{currency}}",
    awaitingVendor: "Order {{number}} is not accepted yet",
    awaitingVendorDetail: "{{minutes}} min past its promise with no merchant acceptance",
    unpaidOrder: "Order {{number}} — cash not collected",
    unpaidOrderDetail: "{{amount}} {{currency}} still to be collected from the customer",
    pendingVendor: "{{name}} is awaiting approval",
    pendingVendorDetail: "Submitted {{minutes}} min ago",
    lateBy: "{{minutes}} min late",
  },

  /** Order status labels. Reached dynamically as `orderStatus.<status>`, so every one must exist. */
  orderStatus: {
    pending: "Pending",
    partially_confirmed: "Partly confirmed",
    preparing: "Preparing",
    ready: "Ready",
    picked_up: "Picked up",
    delivering: "Delivering",
    delivered: "Delivered",
    partially_cancelled: "Partly cancelled",
    cancelled: "Cancelled",
    cash: "Cash",
  },

  dashboard: {
    activeTitle: "Active orders",
    activeEmpty: "No orders in flight right now.",
    todayTitle: "Today",
    capacityTitle: "Merchants and riders",
    analyticsTitle: "Analytics",
    cashRemitted: "Cash collected",
    cashRemittedHint: "Collected by riders",
    /**
     * Named here rather than reusing `variance.cashExpected`.
     *
     * That key reads "Expected in hand" - a cash-float word for the reconciliation screen, where the reader is
     * looking at a settlement. Beside "Cash collected" in a summary band it read as an instruction rather than a
     * figure, so the dashboard states it plainly.
     */
    cashExpected: "Cash expected",
    /**
     * Counts, not a rate.
     *
     * `0 of 1` is a fact an operator can act on; `0.0%` beside a hint repeating `0.0%` reads as two
     * figures that disagree. Interpolation is pluralised by i18next, so this is one key for both numbers.
     */
    completedOfPlaced: "Completed of placed",
    completedOfPlacedValue: "{{delivered}} of {{placed}}",
    onTimeRate: "On time",
    cancellationRate: "Cancelled",
    etaAverage: "Arrival error",
    /** Signed on purpose: "+4" reads late, "-4" reads early, and "4" reads as neither. */
    etaSigned: "{{value}} min",
    etaAverageHint: "Average, late is positive",
    /**
     * A rider-count label rather than a bare status tag. The dashboard shows a "Verified" pill with a count
     * beside it, and the label alone - `ridersVerified` as a number - was both missing and ambiguous: verified
     * out of what?
     */
    ridersVerified: "Verified riders",
    ridersVerifiedHint: "{{count}} verified and online now",
    vendorsCount: "{{count}} merchants",
    dueBy: "Due {{time}}",

    /**
     * The focal order's sub-states, oldest-wait-first wording.
     *
     * A dedicated `status` object rather than reusing `orderStatus.*`: those label a *stored* status, while
     * these describe how urgent the row is. "Delivering, on time" and "Delivering, 12 min late" are the same
     * stored status and very different rows, so the urgency is a separate axis and gets its own words.
     */
    onTime: "On time",
    dueSoon: "Due soon",
    overdue: "Overdue",
    awaitingPickup: "Waiting for the rider",
    /** The count beside the heading, e.g. "Active orders · 3". */
    openOrdersCount: "{{count}} open",

    merchantsTitle: "Merchants",
    ridersTitle: "Riders",

    /**
     * Riders verified, as a fraction of those online.
     *
     * A bare count implied every rider was verified, or that this was the total; `2 of 3` is neither. The
     * `online` interpolation is what makes the row answerable at a glance, which is the whole question a
     * dispatch screen asks.
     */
    ridersVerifiedValue: "{{verified}} of {{online}} online",
    /** Analytics, stated as a deliberate choice rather than a hidden drawer. */
    analyticsHint: "Product telemetry · not part of live operations",
  },
} as const;

export const arAdditions = {
  errors: {
    reasonRequired: "اذكر سببًا. يُسجَّل مع هذا التغيير ويظهر في سجل التدقيق.",
    notFoundHint: "ربما حُذف، أو أن الرابط قديم.",
    alreadyDeleted: "هذا السجل محذوف بالفعل.",
    notDeleted: "هذا السجل غير محذوف، فلا يوجد ما يُستعاد.",
    keyRequired: "رُفض هذا الإجراء (KEY_REQUIRED). أخبر مهندسًا بالرمز بين الأقواس.",
  },

  common: {
    rating: "التقييم",
    createdAt: "تاريخ الانضمام",
  },

  vendor: {
    cancel: "إلغاء",
    title: "التجار",
    searchPlaceholder: "ابحث بالاسم",
    filterVertical: "النوع",
    filterApproved: "الموافقة",
    filterState: "المعروض",
    stateActive: "النشط فقط",
    stateDeleted: "المحذوف فقط",
    stateAll: "النشط والمحذوف",
    approvedAll: "الكل",
    approvedYes: "موافَق عليه",
    approvedNo: "غير موافَق عليه",
    verticalAll: "كل الأنواع",
    verticalFood: "طعام",
    verticalGrocery: "بقالة",
    verticalPharmacy: "صيدلية",
    verticalFlowers: "زهور",
    verticalBakery: "مخبوزات",
    verticalOthers: "أخرى",

    add: "إضافة تاجر",
    edit: "تعديل التاجر",
    open: "فتح",
    delete: "حذف",
    restore: "استعادة",

    empty: "لا يوجد تجار مطابقون لهذه المرشحات.",
    emptyHint: "جرّب بحثًا آخر، أو وسّع المرشحات.",
    showingRange: "{{from}}–{{to}} من {{total}}",
    previous: "السابق",
    next: "التالي",
    pageOf: "صفحة {{page}} من {{pages}}",

    slug: "المعرّف في الرابط",
    slugHint: "حروف إنجليزية صغيرة وأرقام وشرطات. يُستخدم في الروابط.",
    name: "الاسم (إنجليزي)",
    nameAr: "الاسم (عربي)",
    legalName: "الاسم القانوني",
    brand: "العلامة التجارية",
    verticalType: "النوع",
    city: "المدينة",
    area: "المنطقة",
    latitude: "خط العرض",
    longitude: "خط الطول",
    // Transliterated, not translated: "جيوهاش" is the Arabic rendering of the term, and a partial word leaves
    // Latin characters in the middle of an Arabic sentence - which the `i18n.test.ts` leak check catches, and
    // which a bilingual operator reads as a typo.
    geohash: "بادئة الجيوهاش",
    geohashHint: "رمز قصير لهذا الموقع. يُستخدم لتجميع عمليات البحث القريبة.",
    deliveryRadius: "نطاق التوصيل (كم)",
    isOpen: "مفتوح الآن",
    isBusy: "معلَّم كمشغول",
    autoOpen: "يفتح تلقائيًا",
    isApproved: "موافَق عليه",
    isActive: "نشط",
    capacityPerSlot: "طلبات لكل فترة",
    rejectRate: "معدل الرفض",
    deliveryFeeOverride: "تجاوز رسوم التوصيل",
    minimumOrderValue: "أقل قيمة طلب",
    prepTimeMin: "وقت التحضير (دقيقة)",
    prepTimeMax: "أقصى وقت تحضير (دقيقة)",
    logoPath: "مسار الشعار",
    description: "الوصف (إنجليزي)",
    descriptionAr: "الوصف (عربي)",
    contactPhone: "الهاتف",
    contactLandline: "هاتف أرضي",

    groupIdentity: "الهوية",
    groupLocation: "الموقع",
    groupOperations: "التشغيل",
    groupContact: "التواصل",
    groupPricing: "الأرقام",

    createTitle: "تاجر جديد",
    editTitle: "تعديل {{name}}",
    requiredOnCreate: "مطلوب لإنشاء تاجر.",
    noChange: "لم يتغيّر شيء بعد.",
    clear: "إفراغ",

    deleteTitle: "حذف {{name}}؟",
    deleteBody:
      "يختفي التاجر من التطبيق فورًا. تُحفظ طلباته. يُسجَّل السبب أدناه مع اسمك.",
    restoreTitle: "استعادة {{name}}؟",
    restoreBody:
      "يصبح التاجر نشطًا مرة أخرى لكنه يبقى غير موافَق عليه، فلن يظهر في التطبيق حتى توافق عليه.",
    reasonLabel: "السبب",
    reasonPlaceholder: "لماذا يتغيّر هذا؟",
    reasonHint: "يُسجَّل مع هذا التغيير. كن محددًا — أول ما يقرأه أحد لاحقًا.",
    deletedOn: "محذوف",
  },

  status: {
    balanced: "متوازن",
    unbalanced: "غير متوازن",
  },
  attention: {
    title: "يحتاج إلى انتباه",
    clearTitle: "لا شيء يحتاج انتباهًا",
    clearBody: "لا طلبات متأخرة، ولا طلبات لم تُقبَل، ولا كاش غير متوازن.",
    varianceTitle: "الكاش غير متوازن",
    varianceDetail: "{{amount}} {{currency}} غير مفسّرة في {{date}}. افتح التسوية لتسجيل السبب.",
    lateOrder: "الطلب {{number}} متأخر",
    lateOrderDetail: "متأخر {{minutes}} دقيقة عن موعده · {{amount}} {{currency}}",
    awaitingVendor: "الطلب {{number}} لم يُقبَل بعد",
    awaitingVendorDetail: "متأخر {{minutes}} دقيقة عن موعده دون قبول من التاجر",
    unpaidOrder: "الطلب {{number}} — لم يُحصَّل الكاش",
    unpaidOrderDetail: "متبقٍّ {{amount}} {{currency}} للتحصيل من العميل",
    pendingVendor: "{{name}} في انتظار الموافقة",
    pendingVendorDetail: "أُرسل منذ {{minutes}} دقيقة",
    lateBy: "متأخر {{minutes}} دقيقة",
  },

  orderStatus: {
    pending: "قيد الانتظار",
    partially_confirmed: "مؤكد جزئيًا",
    preparing: "قيد التحضير",
    ready: "جاهز",
    picked_up: "تم الاستلام",
    delivering: "قيد التوصيل",
    delivered: "تم التوصيل",
    partially_cancelled: "ملغى جزئيًا",
    cancelled: "ملغى",
    cash: "كاش",
  },

  dashboard: {
    activeTitle: "الطلبات النشطة",
    activeEmpty: "لا توجد طلبات قيد التنفيذ حاليًا.",
    todayTitle: "اليوم",
    capacityTitle: "التجار والسائقون",
    analyticsTitle: "التحليلات",
    cashRemitted: "الكاش المحصّل",
    cashRemittedHint: "حصّله السائقون",
    cashExpected: "الكاش المتوقع",
    completionRate: "مكتملة",
    completedOfPlaced: "مكتملة من المُستلَمة",
    completedOfPlacedValue: "{{delivered}} من {{placed}}",
    onTimeRate: "في الموعد",
    cancellationRate: "ملغاة",
    etaAverage: "فارق الوصول",
    etaSigned: "{{value}} دقيقة",
    etaAverageHint: "المتوسط، والتأخير موجب",
    ridersVerified: "السائقون الموثّقون",
    ridersVerifiedHint: "{{count}} موثّق ومتاح الآن",
    vendorsCount: "{{count}} تجار",
    dueBy: "الموعد {{time}}",

    onTime: "في الموعد",
    dueSoon: "الموعد قريب",
    overdue: "متأخر",
    awaitingPickup: "بانتظار السائق",
    openOrdersCount: "{{count}} مفتوح",

    merchantsTitle: "التجار",
    ridersTitle: "السائقون",

    ridersVerifiedValue: "{{verified}} من {{online}} متاح",
    analyticsHint: "بيانات المنتج · ليست جزءًا من التشغيل الحي",
  },
} as const;