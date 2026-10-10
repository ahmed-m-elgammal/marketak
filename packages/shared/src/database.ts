/**
 * Generated Supabase types for project erxxsebcqqcpkipzcdhg (2026-10-10).
 *
 * DO NOT HAND-EDIT: regenerate via the Supabase MCP `generate_typescript_types`
 * tool. Per AGENTS.md rule 1 these types are `any` at the edge — the app
 * wraps them (hand-written DTOs in `dto.ts`, Zod schemas in the mobile app)
 * and never casts through them. They serve only as generic constraints
 * (RPC names/args, table names) for the typed boundary.
 */
export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      addresses: {
        Row: {
          apartment: string | null
          area_id: string | null
          area_name: string | null
          building: string | null
          created_at: string
          deleted_at: string | null
          delivery_instructions: string | null
          floor: string | null
          geohash: string
          geohash_prefix: string
          id: string
          is_default: boolean
          label: string
          landmark: string | null
          last_used_at: string | null
          latitude: number
          longitude: number
          updated_at: string
          user_id: string
        }
        Insert: {
          apartment?: string | null
          area_id?: string | null
          area_name?: string | null
          building?: string | null
          created_at?: string
          deleted_at?: string | null
          delivery_instructions?: string | null
          floor?: string | null
          geohash: string
          geohash_prefix: string
          id?: string
          is_default?: boolean
          label?: string
          landmark?: string | null
          last_used_at?: string | null
          latitude: number
          longitude: number
          updated_at?: string
          user_id: string
        }
        Update: {
          apartment?: string | null
          area_id?: string | null
          area_name?: string | null
          building?: string | null
          created_at?: string
          deleted_at?: string | null
          delivery_instructions?: string | null
          floor?: string | null
          geohash?: string
          geohash_prefix?: string
          id?: string
          is_default?: boolean
          label?: string
          landmark?: string | null
          last_used_at?: string | null
          latitude?: number
          longitude?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "addresses_area_id_fkey"
            columns: ["area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "addresses_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      areas: {
        Row: {
          center_lat: number
          center_lng: number
          city_id: string
          created_at: string
          deleted_at: string | null
          geohash_prefix: string
          id: string
          is_active: boolean
          name: string
          name_ar: string
          radius_km: number
          slug: string
          updated_at: string
        }
        Insert: {
          center_lat: number
          center_lng: number
          city_id: string
          created_at?: string
          deleted_at?: string | null
          geohash_prefix: string
          id?: string
          is_active?: boolean
          name: string
          name_ar: string
          radius_km?: number
          slug: string
          updated_at?: string
        }
        Update: {
          center_lat?: number
          center_lng?: number
          city_id?: string
          created_at?: string
          deleted_at?: string | null
          geohash_prefix?: string
          id?: string
          is_active?: boolean
          name?: string
          name_ar?: string
          radius_km?: number
          slug?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "areas_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: string
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: number
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: number
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: number
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log_2026_10: {
        Row: {
          action: string
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: number
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: number
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: number
        }
        Relationships: []
      }
      audit_log_2026_11: {
        Row: {
          action: string
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: number
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: number
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: number
        }
        Relationships: []
      }
      auth_daily_stats: {
        Row: {
          business_date: string
          count: number
          event_name: string
          updated_at: string
        }
        Insert: {
          business_date: string
          count?: number
          event_name: string
          updated_at?: string
        }
        Update: {
          business_date?: string
          count?: number
          event_name?: string
          updated_at?: string
        }
        Relationships: []
      }
      brands: {
        Row: {
          created_at: string
          deleted_at: string | null
          id: string
          is_active: boolean
          logo_path: string | null
          name: string
          name_ar: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          logo_path?: string | null
          name: string
          name_ar?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          logo_path?: string | null
          name?: string
          name_ar?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      cart_items: {
        Row: {
          cached_at: string | null
          cached_price: number | null
          cart_id: string
          created_at: string
          display_snapshot: Json | null
          id: string
          menu_item_id: string
          quantity: number
          selected_options: Json
          selected_size_id: string | null
          selected_size_name: string | null
          selected_size_price: number | null
          special_instructions: string | null
          updated_at: string
          vendor_id: string
        }
        Insert: {
          cached_at?: string | null
          cached_price?: number | null
          cart_id: string
          created_at?: string
          display_snapshot?: Json | null
          id?: string
          menu_item_id: string
          quantity: number
          selected_options?: Json
          selected_size_id?: string | null
          selected_size_name?: string | null
          selected_size_price?: number | null
          special_instructions?: string | null
          updated_at?: string
          vendor_id: string
        }
        Update: {
          cached_at?: string | null
          cached_price?: number | null
          cart_id?: string
          created_at?: string
          display_snapshot?: Json | null
          id?: string
          menu_item_id?: string
          quantity?: number
          selected_options?: Json
          selected_size_id?: string | null
          selected_size_name?: string | null
          selected_size_price?: number | null
          special_instructions?: string | null
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cart_items_cart_id_fkey"
            columns: ["cart_id"]
            isOneToOne: false
            referencedRelation: "carts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cart_items_menu_item_id_fkey"
            columns: ["menu_item_id"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cart_items_selected_size_id_fkey"
            columns: ["selected_size_id"]
            isOneToOne: false
            referencedRelation: "menu_item_sizes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cart_items_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      carts: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          last_seen_at: string
          quote_address_id: string | null
          quote_delivery_type: string | null
          quote_expires_at: string | null
          quote_fingerprint: string | null
          quote_grouping: string | null
          quote_id: string | null
          quote_rider_tip: number | null
          quote_snapshot: Json | null
          quote_voucher_code: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          last_seen_at?: string
          quote_address_id?: string | null
          quote_delivery_type?: string | null
          quote_expires_at?: string | null
          quote_fingerprint?: string | null
          quote_grouping?: string | null
          quote_id?: string | null
          quote_rider_tip?: number | null
          quote_snapshot?: Json | null
          quote_voucher_code?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          last_seen_at?: string
          quote_address_id?: string | null
          quote_delivery_type?: string | null
          quote_expires_at?: string | null
          quote_fingerprint?: string | null
          quote_grouping?: string | null
          quote_id?: string | null
          quote_rider_tip?: number | null
          quote_snapshot?: Json | null
          quote_voucher_code?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "carts_quote_address_id_fkey"
            columns: ["quote_address_id"]
            isOneToOne: false
            referencedRelation: "addresses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "carts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      cities: {
        Row: {
          center_lat: number
          center_lng: number
          code: string
          country_code: string
          created_at: string
          currency: string
          deleted_at: string | null
          id: string
          is_active: boolean
          is_primary: boolean
          name: string
          name_ar: string
          timezone: string
          updated_at: string
        }
        Insert: {
          center_lat: number
          center_lng: number
          code: string
          country_code: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          is_primary?: boolean
          name: string
          name_ar: string
          timezone: string
          updated_at?: string
        }
        Update: {
          center_lat?: number
          center_lng?: number
          code?: string
          country_code?: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          is_primary?: boolean
          name?: string
          name_ar?: string
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      commission_rules: {
        Row: {
          applies_to: string
          commission_type: string
          created_at: string
          created_by: string | null
          effective_from: string
          effective_until: string | null
          id: string
          is_active: boolean
          max_amount: number | null
          min_amount: number | null
          scope: string
          target_id: string | null
          updated_at: string
          value: number
          vertical_type: string | null
        }
        Insert: {
          applies_to?: string
          commission_type: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_until?: string | null
          id?: string
          is_active?: boolean
          max_amount?: number | null
          min_amount?: number | null
          scope: string
          target_id?: string | null
          updated_at?: string
          value?: number
          vertical_type?: string | null
        }
        Update: {
          applies_to?: string
          commission_type?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_until?: string | null
          id?: string
          is_active?: boolean
          max_amount?: number | null
          min_amount?: number | null
          scope?: string
          target_id?: string | null
          updated_at?: string
          value?: number
          vertical_type?: string | null
        }
        Relationships: []
      }
      cuisines: {
        Row: {
          code: string
          deleted_at: string | null
          id: string
          name: string
          name_ar: string
          name_ar_normalized: string | null
          name_normalized: string | null
          sort_order: number
          updated_at: string
        }
        Insert: {
          code: string
          deleted_at?: string | null
          id?: string
          name: string
          name_ar: string
          name_ar_normalized?: string | null
          name_normalized?: string | null
          sort_order?: number
          updated_at?: string
        }
        Update: {
          code?: string
          deleted_at?: string | null
          id?: string
          name?: string
          name_ar?: string
          name_ar_normalized?: string | null
          name_normalized?: string | null
          sort_order?: number
          updated_at?: string
        }
        Relationships: []
      }
      delivery_assignments: {
        Row: {
          arrived_at: string | null
          arrived_vendor_at: string | null
          assigned_at: string | null
          assigned_by: string
          claimed_at: string | null
          collected_amount: number | null
          collection_channel: string | null
          collection_method: string | null
          collection_reference: string | null
          created_at: string
          delivered_at: string | null
          distance_km: number | null
          eta_minutes: number | null
          failure_reason: string | null
          id: string
          order_id: string
          picked_up_at: string | null
          platform_revenue: number | null
          proof_path: string | null
          rider_id: string | null
          rider_pay_base: number | null
          rider_pay_bonus: number | null
          rider_pay_distance: number | null
          rider_pay_total: number | null
          signature_path: string | null
          status: string
          stop_sequence: Json | null
          sub_order_id: string | null
          updated_at: string
        }
        Insert: {
          arrived_at?: string | null
          arrived_vendor_at?: string | null
          assigned_at?: string | null
          assigned_by?: string
          claimed_at?: string | null
          collected_amount?: number | null
          collection_channel?: string | null
          collection_method?: string | null
          collection_reference?: string | null
          created_at?: string
          delivered_at?: string | null
          distance_km?: number | null
          eta_minutes?: number | null
          failure_reason?: string | null
          id?: string
          order_id: string
          picked_up_at?: string | null
          platform_revenue?: number | null
          proof_path?: string | null
          rider_id?: string | null
          rider_pay_base?: number | null
          rider_pay_bonus?: number | null
          rider_pay_distance?: number | null
          rider_pay_total?: number | null
          signature_path?: string | null
          status?: string
          stop_sequence?: Json | null
          sub_order_id?: string | null
          updated_at?: string
        }
        Update: {
          arrived_at?: string | null
          arrived_vendor_at?: string | null
          assigned_at?: string | null
          assigned_by?: string
          claimed_at?: string | null
          collected_amount?: number | null
          collection_channel?: string | null
          collection_method?: string | null
          collection_reference?: string | null
          created_at?: string
          delivered_at?: string | null
          distance_km?: number | null
          eta_minutes?: number | null
          failure_reason?: string | null
          id?: string
          order_id?: string
          picked_up_at?: string | null
          platform_revenue?: number | null
          proof_path?: string | null
          rider_id?: string | null
          rider_pay_base?: number | null
          rider_pay_bonus?: number | null
          rider_pay_distance?: number | null
          rider_pay_total?: number | null
          signature_path?: string | null
          status?: string
          stop_sequence?: Json | null
          sub_order_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "delivery_assignments_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "delivery_assignments_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "delivery_assignments_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "delivery_assignments_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      delivery_fee_tiers: {
        Row: {
          created_at: string
          deleted_at: string | null
          multiplier_bps: number
          updated_at: string
          vendor_count: number
          zone_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          multiplier_bps: number
          updated_at?: string
          vendor_count: number
          zone_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          multiplier_bps?: number
          updated_at?: string
          vendor_count?: number
          zone_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "delivery_fee_tiers_zone_id_fkey"
            columns: ["zone_id"]
            isOneToOne: false
            referencedRelation: "delivery_zones"
            referencedColumns: ["id"]
          },
        ]
      }
      delivery_zones: {
        Row: {
          area_id: string
          city_id: string
          created_at: string
          currency: string
          deleted_at: string | null
          delivery_base_fee: number
          free_radius_km: number
          id: string
          is_active: boolean
          max_distance_km: number
          max_vendors_per_order: number
          min_order_value: number
          name: string
          name_ar: string
          peak_hours: unknown
          per_km_fee: number
          updated_at: string
        }
        Insert: {
          area_id: string
          city_id: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          delivery_base_fee?: number
          free_radius_km?: number
          id?: string
          is_active?: boolean
          max_distance_km?: number
          max_vendors_per_order?: number
          min_order_value?: number
          name: string
          name_ar: string
          peak_hours?: unknown
          per_km_fee?: number
          updated_at?: string
        }
        Update: {
          area_id?: string
          city_id?: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          delivery_base_fee?: number
          free_radius_km?: number
          id?: string
          is_active?: boolean
          max_distance_km?: number
          max_vendors_per_order?: number
          min_order_value?: number
          name?: string
          name_ar?: string
          peak_hours?: unknown
          per_km_fee?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "delivery_zones_area_id_fkey"
            columns: ["area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "delivery_zones_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      device_tokens: {
        Row: {
          app_role: string
          app_version: string | null
          created_at: string
          id: string
          language: string
          last_seen_at: string
          platform: string
          token: string
          user_id: string
        }
        Insert: {
          app_role: string
          app_version?: string | null
          created_at?: string
          id?: string
          language?: string
          last_seen_at?: string
          platform: string
          token: string
          user_id: string
        }
        Update: {
          app_role?: string
          app_version?: string | null
          created_at?: string
          id?: string
          language?: string
          last_seen_at?: string
          platform?: string
          token?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_tokens_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_shifts: {
        Row: {
          area_ids: string[]
          created_at: string
          ends_at: string
          id: string
          is_active: boolean
          rider_id: string
          starts_at: string
        }
        Insert: {
          area_ids?: string[]
          created_at?: string
          ends_at: string
          id?: string
          is_active?: boolean
          rider_id: string
          starts_at: string
        }
        Update: {
          area_ids?: string[]
          created_at?: string
          ends_at?: string
          id?: string
          is_active?: boolean
          rider_id?: string
          starts_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_shifts_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_shifts_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
        ]
      }
      event_daily_stats: {
        Row: {
          app_role: string
          business_date: string
          city_id: string
          count: number
          event_name: string
          unique_users: number
          updated_at: string
        }
        Insert: {
          app_role: string
          business_date: string
          city_id: string
          count?: number
          event_name: string
          unique_users?: number
          updated_at?: string
        }
        Update: {
          app_role?: string
          business_date?: string
          city_id?: string
          count?: number
          event_name?: string
          unique_users?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "event_daily_stats_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      events: {
        Row: {
          aggregate_id: string | null
          aggregate_type: string | null
          attempts: number
          created_at: string
          delivered_at: string | null
          id: number
          id_uuid: string
          last_error: string | null
          payload: Json
          type: string
        }
        Insert: {
          aggregate_id?: string | null
          aggregate_type?: string | null
          attempts?: number
          created_at?: string
          delivered_at?: string | null
          id?: number
          id_uuid?: string
          last_error?: string | null
          payload: Json
          type: string
        }
        Update: {
          aggregate_id?: string | null
          aggregate_type?: string | null
          attempts?: number
          created_at?: string
          delivered_at?: string | null
          id?: number
          id_uuid?: string
          last_error?: string | null
          payload?: Json
          type?: string
        }
        Relationships: []
      }
      favorite_items: {
        Row: {
          created_at: string
          menu_item_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          menu_item_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          menu_item_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "favorite_items_menu_item_id_fkey"
            columns: ["menu_item_id"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "favorite_items_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      favorites: {
        Row: {
          created_at: string
          user_id: string
          vendor_id: string
        }
        Insert: {
          created_at?: string
          user_id: string
          vendor_id: string
        }
        Update: {
          created_at?: string
          user_id?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "favorites_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "favorites_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      feature_flags: {
        Row: {
          deleted_at: string | null
          description: string | null
          flag_key: string
          id: string
          is_active: boolean
          targeting_rules: Json
          updated_at: string
          updated_by: string | null
          value: Json
          value_type: string
        }
        Insert: {
          deleted_at?: string | null
          description?: string | null
          flag_key: string
          id?: string
          is_active?: boolean
          targeting_rules?: Json
          updated_at?: string
          updated_by?: string | null
          value: Json
          value_type: string
        }
        Update: {
          deleted_at?: string | null
          description?: string | null
          flag_key?: string
          id?: string
          is_active?: boolean
          targeting_rules?: Json
          updated_at?: string
          updated_by?: string | null
          value?: Json
          value_type?: string
        }
        Relationships: []
      }
      item_options: {
        Row: {
          created_at: string
          deleted_at: string | null
          display_order: number
          id: string
          is_available: boolean
          is_required: boolean
          item_id: string
          max_selections: number
          min_selections: number
          name: string
          name_ar: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_required?: boolean
          item_id: string
          max_selections?: number
          min_selections?: number
          name: string
          name_ar?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_required?: boolean
          item_id?: string
          max_selections?: number
          min_selections?: number
          name?: string
          name_ar?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "item_options_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["id"]
          },
        ]
      }
      ledger_entries: {
        Row: {
          account_id: string | null
          account_type: string
          created_at: string
          currency: string
          entry_type: string
          id: string
          idempotency_key: string
          metadata: Json | null
          note: string | null
          order_id: string | null
          payout_id: string | null
          signed_amount: number
          sub_order_id: string | null
        }
        Insert: {
          account_id?: string | null
          account_type: string
          created_at?: string
          currency?: string
          entry_type: string
          id?: string
          idempotency_key: string
          metadata?: Json | null
          note?: string | null
          order_id?: string | null
          payout_id?: string | null
          signed_amount: number
          sub_order_id?: string | null
        }
        Update: {
          account_id?: string | null
          account_type?: string
          created_at?: string
          currency?: string
          entry_type?: string
          id?: string
          idempotency_key?: string
          metadata?: Json | null
          note?: string | null
          order_id?: string | null
          payout_id?: string | null
          signed_amount?: number
          sub_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ledger_entries_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ledger_entries_payout_id_fkey"
            columns: ["payout_id"]
            isOneToOne: false
            referencedRelation: "payouts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ledger_entries_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      menu_categories: {
        Row: {
          created_at: string
          deleted_at: string | null
          description: string | null
          display_order: number
          id: string
          is_available: boolean
          name: string
          name_ar: string | null
          name_ar_normalized: string | null
          name_normalized: string | null
          updated_at: string
          vendor_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          name: string
          name_ar?: string | null
          name_ar_normalized?: string | null
          name_normalized?: string | null
          updated_at?: string
          vendor_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          name?: string
          name_ar?: string | null
          name_ar_normalized?: string | null
          name_normalized?: string | null
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "menu_categories_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      menu_item_sizes: {
        Row: {
          calories: number | null
          created_at: string
          deleted_at: string | null
          display_order: number
          id: string
          is_available: boolean
          is_default: boolean
          item_id: string
          name: string
          name_ar: string | null
          price: number
          updated_at: string
        }
        Insert: {
          calories?: number | null
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_default?: boolean
          item_id: string
          name: string
          name_ar?: string | null
          price: number
          updated_at?: string
        }
        Update: {
          calories?: number | null
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_default?: boolean
          item_id?: string
          name?: string
          name_ar?: string | null
          price?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "menu_item_sizes_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["id"]
          },
        ]
      }
      menu_items: {
        Row: {
          allergens: Json | null
          base_price: number | null
          calories: number | null
          category_id: string
          created_at: string
          deleted_at: string | null
          description: string | null
          description_ar: string | null
          display_order: number
          id: string
          image_path: string | null
          ingredients: Json | null
          ingredients_normalized: string | null
          is_available: boolean
          is_featured: boolean
          is_new: boolean
          is_spicy: boolean
          is_vegetarian: boolean
          name: string
          name_ar: string | null
          name_ar_normalized: string | null
          name_normalized: string | null
          nutritional_info: Json | null
          preparation_time_minutes: number | null
          pricing_mode: string
          stock_count: number | null
          tags: string[]
          updated_at: string
          vendor_id: string
        }
        Insert: {
          allergens?: Json | null
          base_price?: number | null
          calories?: number | null
          category_id: string
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          description_ar?: string | null
          display_order?: number
          id?: string
          image_path?: string | null
          ingredients?: Json | null
          ingredients_normalized?: string | null
          is_available?: boolean
          is_featured?: boolean
          is_new?: boolean
          is_spicy?: boolean
          is_vegetarian?: boolean
          name: string
          name_ar?: string | null
          name_ar_normalized?: string | null
          name_normalized?: string | null
          nutritional_info?: Json | null
          preparation_time_minutes?: number | null
          pricing_mode?: string
          stock_count?: number | null
          tags?: string[]
          updated_at?: string
          vendor_id: string
        }
        Update: {
          allergens?: Json | null
          base_price?: number | null
          calories?: number | null
          category_id?: string
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          description_ar?: string | null
          display_order?: number
          id?: string
          image_path?: string | null
          ingredients?: Json | null
          ingredients_normalized?: string | null
          is_available?: boolean
          is_featured?: boolean
          is_new?: boolean
          is_spicy?: boolean
          is_vegetarian?: boolean
          name?: string
          name_ar?: string | null
          name_ar_normalized?: string | null
          name_normalized?: string | null
          nutritional_info?: Json | null
          preparation_time_minutes?: number | null
          pricing_mode?: string
          stock_count?: number | null
          tags?: string[]
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "menu_items_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "menu_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "menu_items_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_templates: {
        Row: {
          body: string
          channel: string
          deleted_at: string | null
          id: string
          is_active: boolean
          key: string
          lang: string
          title: string
          updated_at: string
          variables: Json
        }
        Insert: {
          body: string
          channel?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          key: string
          lang: string
          title: string
          updated_at?: string
          variables?: Json
        }
        Update: {
          body?: string
          channel?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          key?: string
          lang?: string
          title?: string
          updated_at?: string
          variables?: Json
        }
        Relationships: []
      }
      notifications: {
        Row: {
          body: Json
          created_at: string
          data: Json | null
          id: number
          order_id: string | null
          read_at: string | null
          sub_order_id: string | null
          title: Json
          type: string
          user_id: string
        }
        Insert: {
          body: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title: Json
          type: string
          user_id: string
        }
        Update: {
          body?: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title?: Json
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications_2026_10: {
        Row: {
          body: Json
          created_at: string
          data: Json | null
          id: number
          order_id: string | null
          read_at: string | null
          sub_order_id: string | null
          title: Json
          type: string
          user_id: string
        }
        Insert: {
          body: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title: Json
          type: string
          user_id: string
        }
        Update: {
          body?: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title?: Json
          type?: string
          user_id?: string
        }
        Relationships: []
      }
      notifications_2026_11: {
        Row: {
          body: Json
          created_at: string
          data: Json | null
          id: number
          order_id: string | null
          read_at: string | null
          sub_order_id: string | null
          title: Json
          type: string
          user_id: string
        }
        Insert: {
          body: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title: Json
          type: string
          user_id: string
        }
        Update: {
          body?: Json
          created_at?: string
          data?: Json | null
          id?: number
          order_id?: string | null
          read_at?: string | null
          sub_order_id?: string | null
          title?: Json
          type?: string
          user_id?: string
        }
        Relationships: []
      }
      option_choices: {
        Row: {
          calories: number | null
          created_at: string
          deleted_at: string | null
          display_order: number
          id: string
          is_available: boolean
          is_default: boolean
          name: string
          name_ar: string | null
          option_id: string
          price_modifier: number
          stock_count: number | null
          updated_at: string
        }
        Insert: {
          calories?: number | null
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_default?: boolean
          name: string
          name_ar?: string | null
          option_id: string
          price_modifier?: number
          stock_count?: number | null
          updated_at?: string
        }
        Update: {
          calories?: number | null
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          is_available?: boolean
          is_default?: boolean
          name?: string
          name_ar?: string | null
          option_id?: string
          price_modifier?: number
          stock_count?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "option_choices_option_id_fkey"
            columns: ["option_id"]
            isOneToOne: false
            referencedRelation: "item_options"
            referencedColumns: ["id"]
          },
        ]
      }
      order_eta_snapshots: {
        Row: {
          computed_at: string
          id: string
          order_id: string
          predicted_at: string
          promised_at: string
          sub_order_id: string | null
        }
        Insert: {
          computed_at?: string
          id?: string
          order_id: string
          predicted_at: string
          promised_at: string
          sub_order_id?: string | null
        }
        Update: {
          computed_at?: string
          id?: string
          order_id?: string
          predicted_at?: string
          promised_at?: string
          sub_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "order_eta_snapshots_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_eta_snapshots_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      order_items: {
        Row: {
          created_at: string
          id: string
          image_path: string | null
          item_name: string
          item_name_ar: string | null
          item_status: string
          menu_item_id: string | null
          order_id: string
          quantity: number
          selected_options: Json
          selected_size_id: string | null
          selected_size_name: string | null
          selected_size_price: number | null
          special_instructions: string | null
          sub_order_id: string
          total_price: number
          unit_price: number
          vendor_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          image_path?: string | null
          item_name: string
          item_name_ar?: string | null
          item_status?: string
          menu_item_id?: string | null
          order_id: string
          quantity: number
          selected_options?: Json
          selected_size_id?: string | null
          selected_size_name?: string | null
          selected_size_price?: number | null
          special_instructions?: string | null
          sub_order_id: string
          total_price: number
          unit_price: number
          vendor_id: string
        }
        Update: {
          created_at?: string
          id?: string
          image_path?: string | null
          item_name?: string
          item_name_ar?: string | null
          item_status?: string
          menu_item_id?: string | null
          order_id?: string
          quantity?: number
          selected_options?: Json
          selected_size_id?: string | null
          selected_size_name?: string | null
          selected_size_price?: number | null
          special_instructions?: string | null
          sub_order_id?: string
          total_price?: number
          unit_price?: number
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "order_items_menu_item_id_fkey"
            columns: ["menu_item_id"]
            isOneToOne: false
            referencedRelation: "menu_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_selected_size_id_fkey"
            columns: ["selected_size_id"]
            isOneToOne: false
            referencedRelation: "menu_item_sizes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      order_modifications: {
        Row: {
          actor_user_id: string | null
          created_at: string
          customer_approved: boolean | null
          difference_amount: number
          id: string
          modification_type: string
          new_total: number
          order_id: string
          order_item_id: string | null
          original_total: number
          reason: string | null
          sub_order_id: string | null
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          customer_approved?: boolean | null
          difference_amount: number
          id?: string
          modification_type: string
          new_total: number
          order_id: string
          order_item_id?: string | null
          original_total: number
          reason?: string | null
          sub_order_id?: string | null
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          customer_approved?: boolean | null
          difference_amount?: number
          id?: string
          modification_type?: string
          new_total?: number
          order_id?: string
          order_item_id?: string | null
          original_total?: number
          reason?: string | null
          sub_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "order_modifications_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_modifications_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_modifications_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_modifications_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      order_status_history: {
        Row: {
          actor_role: string
          actor_user_id: string | null
          created_at: string
          from_status: string | null
          id: string
          metadata: Json | null
          order_id: string
          reason: string | null
          sub_order_id: string | null
          to_status: string
        }
        Insert: {
          actor_role: string
          actor_user_id?: string | null
          created_at?: string
          from_status?: string | null
          id?: string
          metadata?: Json | null
          order_id: string
          reason?: string | null
          sub_order_id?: string | null
          to_status: string
        }
        Update: {
          actor_role?: string
          actor_user_id?: string | null
          created_at?: string
          from_status?: string | null
          id?: string
          metadata?: Json | null
          order_id?: string
          reason?: string | null
          sub_order_id?: string | null
          to_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "order_status_history_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_status_history_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_status_history_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      orders: {
        Row: {
          access_note: string | null
          address_id: string | null
          address_snapshot: Json
          area_id: string | null
          cancellation_actor_id: string | null
          cancellation_reason: string | null
          cancelled_at: string | null
          completed_at: string | null
          confirmed_at: string | null
          created_at: string
          currency: string
          delivery_base_fee: number
          delivery_fee: number
          delivery_geohash_prefix: string | null
          delivery_grouping: string
          delivery_latitude: number | null
          delivery_longitude: number | null
          delivery_multiplier_bps: number
          delivery_type: string
          discount_amount: number
          distance_km: number | null
          eta_maxutes: number | null
          eta_minutes: number | null
          first_picked_up_at: string | null
          id: string
          idempotency_key: string | null
          is_contactless: boolean
          item_count: number
          order_number: string
          payment_channel: string | null
          payment_collected_at: string | null
          payment_collected_by: string | null
          payment_method: string | null
          payment_proof_path: string | null
          payment_reference: string | null
          payment_status: string
          placed_at: string
          platform_revenue: number
          price_fingerprint: string | null
          pricing_version: number
          promised_delivery_at: string | null
          rider_pay_total: number
          rider_tip: number
          scheduled_delivery_time: string | null
          service_fee: number
          status: string
          subtotal: number
          total: number
          updated_at: string
          user_id: string
          vendor_count: number
          vendor_limit_applied: number | null
          voucher_code: string | null
          voucher_discount: number
        }
        Insert: {
          access_note?: string | null
          address_id?: string | null
          address_snapshot: Json
          area_id?: string | null
          cancellation_actor_id?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          completed_at?: string | null
          confirmed_at?: string | null
          created_at?: string
          currency?: string
          delivery_base_fee?: number
          delivery_fee?: number
          delivery_geohash_prefix?: string | null
          delivery_grouping?: string
          delivery_latitude?: number | null
          delivery_longitude?: number | null
          delivery_multiplier_bps?: number
          delivery_type?: string
          discount_amount?: number
          distance_km?: number | null
          eta_maxutes?: number | null
          eta_minutes?: number | null
          first_picked_up_at?: string | null
          id?: string
          idempotency_key?: string | null
          is_contactless?: boolean
          item_count?: number
          order_number: string
          payment_channel?: string | null
          payment_collected_at?: string | null
          payment_collected_by?: string | null
          payment_method?: string | null
          payment_proof_path?: string | null
          payment_reference?: string | null
          payment_status?: string
          placed_at?: string
          platform_revenue?: number
          price_fingerprint?: string | null
          pricing_version?: number
          promised_delivery_at?: string | null
          rider_pay_total?: number
          rider_tip?: number
          scheduled_delivery_time?: string | null
          service_fee?: number
          status?: string
          subtotal?: number
          total?: number
          updated_at?: string
          user_id: string
          vendor_count?: number
          vendor_limit_applied?: number | null
          voucher_code?: string | null
          voucher_discount?: number
        }
        Update: {
          access_note?: string | null
          address_id?: string | null
          address_snapshot?: Json
          area_id?: string | null
          cancellation_actor_id?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          completed_at?: string | null
          confirmed_at?: string | null
          created_at?: string
          currency?: string
          delivery_base_fee?: number
          delivery_fee?: number
          delivery_geohash_prefix?: string | null
          delivery_grouping?: string
          delivery_latitude?: number | null
          delivery_longitude?: number | null
          delivery_multiplier_bps?: number
          delivery_type?: string
          discount_amount?: number
          distance_km?: number | null
          eta_maxutes?: number | null
          eta_minutes?: number | null
          first_picked_up_at?: string | null
          id?: string
          idempotency_key?: string | null
          is_contactless?: boolean
          item_count?: number
          order_number?: string
          payment_channel?: string | null
          payment_collected_at?: string | null
          payment_collected_by?: string | null
          payment_method?: string | null
          payment_proof_path?: string | null
          payment_reference?: string | null
          payment_status?: string
          placed_at?: string
          platform_revenue?: number
          price_fingerprint?: string | null
          pricing_version?: number
          promised_delivery_at?: string | null
          rider_pay_total?: number
          rider_tip?: number
          scheduled_delivery_time?: string | null
          service_fee?: number
          status?: string
          subtotal?: number
          total?: number
          updated_at?: string
          user_id?: string
          vendor_count?: number
          vendor_limit_applied?: number | null
          voucher_code?: string | null
          voucher_discount?: number
        }
        Relationships: [
          {
            foreignKeyName: "orders_address_id_fkey"
            columns: ["address_id"]
            isOneToOne: false
            referencedRelation: "addresses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_area_id_fkey"
            columns: ["area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_cancellation_actor_id_fkey"
            columns: ["cancellation_actor_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_payment_collected_by_fkey"
            columns: ["payment_collected_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      payout_lines: {
        Row: {
          assignment_id: string | null
          created_at: string
          fee_amount: number
          gross_amount: number
          id: string
          net_amount: number
          payout_id: string
          payout_line_type: string
          source: string
          sub_order_id: string | null
        }
        Insert: {
          assignment_id?: string | null
          created_at?: string
          fee_amount?: number
          gross_amount: number
          id?: string
          net_amount: number
          payout_id: string
          payout_line_type: string
          source: string
          sub_order_id?: string | null
        }
        Update: {
          assignment_id?: string | null
          created_at?: string
          fee_amount?: number
          gross_amount?: number
          id?: string
          net_amount?: number
          payout_id?: string
          payout_line_type?: string
          source?: string
          sub_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payout_lines_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: false
            referencedRelation: "delivery_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payout_lines_payout_id_fkey"
            columns: ["payout_id"]
            isOneToOne: false
            referencedRelation: "payouts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payout_lines_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      payouts: {
        Row: {
          account_id: string
          approved_at: string | null
          approved_by: string | null
          created_at: string
          currency: string
          failure_reason: string | null
          fee_amount: number
          gross_amount: number
          id: string
          idempotency_key: string
          method: string | null
          net_amount: number
          paid_at: string | null
          payout_type: string
          period_end: string
          period_start: string
          reference: string | null
          status: string
          updated_at: string
        }
        Insert: {
          account_id: string
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          currency?: string
          failure_reason?: string | null
          fee_amount?: number
          gross_amount?: number
          id?: string
          idempotency_key: string
          method?: string | null
          net_amount?: number
          paid_at?: string | null
          payout_type: string
          period_end: string
          period_start: string
          reference?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          account_id?: string
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          currency?: string
          failure_reason?: string | null
          fee_amount?: number
          gross_amount?: number
          id?: string
          idempotency_key?: string
          method?: string | null
          net_amount?: number
          paid_at?: string | null
          payout_type?: string
          period_end?: string
          period_start?: string
          reference?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payouts_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_float: {
        Row: {
          adjustments: number
          business_date: string
          cash_expected: number
          cash_remitted: number
          commissions: number
          delivery_fees: number
          external_cash_orders: number
          external_wallet_orders: number
          id: string
          rider_cuts: number
          rider_payable: number
          service_fees: number
          updated_at: string
          variance: number
          variance_explained_amount: number | null
          variance_explained_at: string | null
          variance_explanation: string | null
          vendor_payable: number
        }
        Insert: {
          adjustments?: number
          business_date: string
          cash_expected?: number
          cash_remitted?: number
          commissions?: number
          delivery_fees?: number
          external_cash_orders?: number
          external_wallet_orders?: number
          id?: string
          rider_cuts?: number
          rider_payable?: number
          service_fees?: number
          updated_at?: string
          variance?: number
          variance_explained_amount?: number | null
          variance_explained_at?: string | null
          variance_explanation?: string | null
          vendor_payable?: number
        }
        Update: {
          adjustments?: number
          business_date?: string
          cash_expected?: number
          cash_remitted?: number
          commissions?: number
          delivery_fees?: number
          external_cash_orders?: number
          external_wallet_orders?: number
          id?: string
          rider_cuts?: number
          rider_payable?: number
          service_fees?: number
          updated_at?: string
          variance?: number
          variance_explained_amount?: number | null
          variance_explained_at?: string | null
          variance_explanation?: string | null
          vendor_payable?: number
        }
        Relationships: []
      }
      promo_slots: {
        Row: {
          city_id: string
          created_at: string
          deleted_at: string | null
          ends_at: string | null
          id: string
          image_path: string | null
          is_active: boolean
          slot_key: string
          sort_order: number
          starts_at: string | null
          subtitle: Json | null
          target_id: string | null
          target_type: string | null
          title: Json
          updated_at: string
        }
        Insert: {
          city_id: string
          created_at?: string
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          image_path?: string | null
          is_active?: boolean
          slot_key: string
          sort_order?: number
          starts_at?: string | null
          subtitle?: Json | null
          target_id?: string | null
          target_type?: string | null
          title: Json
          updated_at?: string
        }
        Update: {
          city_id?: string
          created_at?: string
          deleted_at?: string | null
          ends_at?: string | null
          id?: string
          image_path?: string | null
          is_active?: boolean
          slot_key?: string
          sort_order?: number
          starts_at?: string | null
          subtitle?: Json | null
          target_id?: string | null
          target_type?: string | null
          title?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "promo_slots_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      reviews: {
        Row: {
          comment: string | null
          created_at: string
          id: string
          is_hidden: boolean
          order_id: string
          rider_id: string | null
          rider_rating: number | null
          sub_order_id: string | null
          updated_at: string
          user_id: string
          vendor_id: string
          vendor_rating: number | null
        }
        Insert: {
          comment?: string | null
          created_at?: string
          id?: string
          is_hidden?: boolean
          order_id: string
          rider_id?: string | null
          rider_rating?: number | null
          sub_order_id?: string | null
          updated_at?: string
          user_id: string
          vendor_id: string
          vendor_rating?: number | null
        }
        Update: {
          comment?: string | null
          created_at?: string
          id?: string
          is_hidden?: boolean
          order_id?: string
          rider_id?: string | null
          rider_rating?: number | null
          sub_order_id?: string | null
          updated_at?: string
          user_id?: string
          vendor_id?: string
          vendor_rating?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "reviews_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reviews_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reviews_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reviews_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reviews_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reviews_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      rider_earnings_daily: {
        Row: {
          base_fees: number
          bonuses: number
          business_date: string
          cash_held: number
          cash_remitted: number
          deductions: number
          deleted_at: string | null
          deliveries: number
          distance_fees: number
          legs: number
          net_payout: number
          online_minutes: number
          rider_id: string
          tips: number
          updated_at: string
        }
        Insert: {
          base_fees?: number
          bonuses?: number
          business_date: string
          cash_held?: number
          cash_remitted?: number
          deductions?: number
          deleted_at?: string | null
          deliveries?: number
          distance_fees?: number
          legs?: number
          net_payout?: number
          online_minutes?: number
          rider_id: string
          tips?: number
          updated_at?: string
        }
        Update: {
          base_fees?: number
          bonuses?: number
          business_date?: string
          cash_held?: number
          cash_remitted?: number
          deductions?: number
          deleted_at?: string | null
          deliveries?: number
          distance_fees?: number
          legs?: number
          net_payout?: number
          online_minutes?: number
          rider_id?: string
          tips?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "rider_earnings_daily_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rider_earnings_daily_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
        ]
      }
      rider_location_pings: {
        Row: {
          accuracy_m: number | null
          heading: number | null
          id: number
          latitude: number
          longitude: number
          order_id: string
          recorded_at: string
          rider_id: string
          speed_kmh: number | null
        }
        Insert: {
          accuracy_m?: number | null
          heading?: number | null
          id?: number
          latitude: number
          longitude: number
          order_id: string
          recorded_at?: string
          rider_id: string
          speed_kmh?: number | null
        }
        Update: {
          accuracy_m?: number | null
          heading?: number | null
          id?: number
          latitude?: number
          longitude?: number
          order_id?: string
          recorded_at?: string
          rider_id?: string
          speed_kmh?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "rider_location_pings_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rider_location_pings_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rider_location_pings_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
        ]
      }
      rider_pay_rules: {
        Row: {
          bonus_per_leg: number
          city_id: string
          created_at: string
          effective_from: string
          effective_until: string | null
          id: string
          is_active: boolean
          pct_of_delivery_fee_bps: number
          per_km_amount: number
          per_trip_amount: number
          rider_id: string | null
          updated_at: string
        }
        Insert: {
          bonus_per_leg?: number
          city_id: string
          created_at?: string
          effective_from?: string
          effective_until?: string | null
          id?: string
          is_active?: boolean
          pct_of_delivery_fee_bps?: number
          per_km_amount?: number
          per_trip_amount?: number
          rider_id?: string | null
          updated_at?: string
        }
        Update: {
          bonus_per_leg?: number
          city_id?: string
          created_at?: string
          effective_from?: string
          effective_until?: string | null
          id?: string
          is_active?: boolean
          pct_of_delivery_fee_bps?: number
          per_km_amount?: number
          per_trip_amount?: number
          rider_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "rider_pay_rules_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rider_pay_rules_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rider_pay_rules_rider_id_fkey"
            columns: ["rider_id"]
            isOneToOne: false
            referencedRelation: "riders_public"
            referencedColumns: ["id"]
          },
        ]
      }
      riders: {
        Row: {
          cancelled_deliveries: number
          cash_held: number
          completed_deliveries: number
          country_code: string
          created_at: string
          current_geohash: string | null
          current_latitude: number | null
          current_longitude: number | null
          first_name: string
          home_area_id: string | null
          id: string
          is_active: boolean
          is_online: boolean
          is_verified: boolean
          last_location_at: string | null
          last_name: string | null
          max_cash_held: number | null
          phone_number: string
          rating_avg: number
          rating_count: number
          status: string
          updated_at: string
          user_id: string | null
          vehicle_plate: string | null
          vehicle_type: string
        }
        Insert: {
          cancelled_deliveries?: number
          cash_held?: number
          completed_deliveries?: number
          country_code: string
          created_at?: string
          current_geohash?: string | null
          current_latitude?: number | null
          current_longitude?: number | null
          first_name: string
          home_area_id?: string | null
          id?: string
          is_active?: boolean
          is_online?: boolean
          is_verified?: boolean
          last_location_at?: string | null
          last_name?: string | null
          max_cash_held?: number | null
          phone_number: string
          rating_avg?: number
          rating_count?: number
          status?: string
          updated_at?: string
          user_id?: string | null
          vehicle_plate?: string | null
          vehicle_type: string
        }
        Update: {
          cancelled_deliveries?: number
          cash_held?: number
          completed_deliveries?: number
          country_code?: string
          created_at?: string
          current_geohash?: string | null
          current_latitude?: number | null
          current_longitude?: number | null
          first_name?: string
          home_area_id?: string | null
          id?: string
          is_active?: boolean
          is_online?: boolean
          is_verified?: boolean
          last_location_at?: string | null
          last_name?: string | null
          max_cash_held?: number | null
          phone_number?: string
          rating_avg?: number
          rating_count?: number
          status?: string
          updated_at?: string
          user_id?: string | null
          vehicle_plate?: string | null
          vehicle_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "riders_home_area_id_fkey"
            columns: ["home_area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "riders_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      search_daily_stats: {
        Row: {
          business_date: string
          city_id: string
          clicks: number
          query_hash: string
          results_count: number
          updated_at: string
          zero_result: boolean
        }
        Insert: {
          business_date: string
          city_id: string
          clicks?: number
          query_hash: string
          results_count: number
          updated_at?: string
          zero_result?: boolean
        }
        Update: {
          business_date?: string
          city_id?: string
          clicks?: number
          query_hash?: string
          results_count?: number
          updated_at?: string
          zero_result?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "search_daily_stats_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      settings: {
        Row: {
          deleted_at: string | null
          description: string | null
          key: string
          updated_at: string
          updated_by: string | null
          value: Json
        }
        Insert: {
          deleted_at?: string | null
          description?: string | null
          key: string
          updated_at?: string
          updated_by?: string | null
          value: Json
        }
        Update: {
          deleted_at?: string | null
          description?: string | null
          key?: string
          updated_at?: string
          updated_by?: string | null
          value?: Json
        }
        Relationships: []
      }
      sub_orders: {
        Row: {
          accepted_at: string | null
          cancellation_actor: string | null
          cancellation_reason: string | null
          cancelled_at: string | null
          commission_amount: number
          created_at: string
          delivered_at: string | null
          delivery_fee_share: number
          discount_share: number
          id: string
          menu_version_snapshot: number | null
          order_id: string
          payout_id: string | null
          picked_up_at: string | null
          platform_fee_amount: number
          prep_actual_minutes: number | null
          prep_estimate_minutes: number
          preparing_at: string | null
          ready_at: string | null
          rejection_reason: string | null
          sequence: number
          service_fee_share: number
          settlement_status: string
          status: string
          subtotal: number
          updated_at: string
          vendor_id: string
          vendor_net_payout: number
        }
        Insert: {
          accepted_at?: string | null
          cancellation_actor?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          commission_amount?: number
          created_at?: string
          delivered_at?: string | null
          delivery_fee_share?: number
          discount_share?: number
          id?: string
          menu_version_snapshot?: number | null
          order_id: string
          payout_id?: string | null
          picked_up_at?: string | null
          platform_fee_amount?: number
          prep_actual_minutes?: number | null
          prep_estimate_minutes?: number
          preparing_at?: string | null
          ready_at?: string | null
          rejection_reason?: string | null
          sequence: number
          service_fee_share?: number
          settlement_status?: string
          status?: string
          subtotal?: number
          updated_at?: string
          vendor_id: string
          vendor_net_payout?: number
        }
        Update: {
          accepted_at?: string | null
          cancellation_actor?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          commission_amount?: number
          created_at?: string
          delivered_at?: string | null
          delivery_fee_share?: number
          discount_share?: number
          id?: string
          menu_version_snapshot?: number | null
          order_id?: string
          payout_id?: string | null
          picked_up_at?: string | null
          platform_fee_amount?: number
          prep_actual_minutes?: number | null
          prep_estimate_minutes?: number
          preparing_at?: string | null
          ready_at?: string | null
          rejection_reason?: string | null
          sequence?: number
          service_fee_share?: number
          settlement_status?: string
          status?: string
          subtotal?: number
          updated_at?: string
          vendor_id?: string
          vendor_net_payout?: number
        }
        Relationships: [
          {
            foreignKeyName: "sub_orders_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sub_orders_payout_id_fkey"
            columns: ["payout_id"]
            isOneToOne: false
            referencedRelation: "payouts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sub_orders_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      user_auth_providers: {
        Row: {
          deleted_at: string | null
          id: string
          linked_at: string
          provider_id: string
          provider_type: string
          user_id: string
        }
        Insert: {
          deleted_at?: string | null
          id?: string
          linked_at?: string
          provider_id: string
          provider_type: string
          user_id: string
        }
        Update: {
          deleted_at?: string | null
          id?: string
          linked_at?: string
          provider_id?: string
          provider_type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_auth_providers_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          granted_at: string
          granted_by: string | null
          revoked_at: string | null
          role: string
          user_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          revoked_at?: string | null
          role: string
          user_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          revoked_at?: string | null
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_roles_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      users: {
        Row: {
          avatar_path: string | null
          country_code: string
          created_at: string
          deleted_at: string | null
          email: string | null
          first_name: string | null
          id: string
          is_active: boolean
          last_name: string | null
          last_seen_at: string | null
          phone_number: string | null
          preferred_language: string
          profile_completed_at: string | null
          updated_at: string
        }
        Insert: {
          avatar_path?: string | null
          country_code?: string
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          first_name?: string | null
          id: string
          is_active?: boolean
          last_name?: string | null
          last_seen_at?: string | null
          phone_number?: string | null
          preferred_language?: string
          profile_completed_at?: string | null
          updated_at?: string
        }
        Update: {
          avatar_path?: string | null
          country_code?: string
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          first_name?: string | null
          id?: string
          is_active?: boolean
          last_name?: string | null
          last_seen_at?: string | null
          phone_number?: string | null
          preferred_language?: string
          profile_completed_at?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      vendor_areas: {
        Row: {
          area_id: string
          deleted_at: string | null
          delivery_fee_override: number | null
          eta_maxutes: number
          eta_minutes: number
          is_active: boolean
          updated_at: string
          vendor_id: string
        }
        Insert: {
          area_id: string
          deleted_at?: string | null
          delivery_fee_override?: number | null
          eta_maxutes?: number
          eta_minutes?: number
          is_active?: boolean
          updated_at?: string
          vendor_id: string
        }
        Update: {
          area_id?: string
          deleted_at?: string | null
          delivery_fee_override?: number | null
          eta_maxutes?: number
          eta_minutes?: number
          is_active?: boolean
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_areas_area_id_fkey"
            columns: ["area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_areas_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_cuisines: {
        Row: {
          cuisine_id: string
          deleted_at: string | null
          updated_at: string
          vendor_id: string
        }
        Insert: {
          cuisine_id: string
          deleted_at?: string | null
          updated_at?: string
          vendor_id: string
        }
        Update: {
          cuisine_id?: string
          deleted_at?: string | null
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_cuisines_cuisine_id_fkey"
            columns: ["cuisine_id"]
            isOneToOne: false
            referencedRelation: "cuisines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_cuisines_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_earnings_daily: {
        Row: {
          adjustments: number
          business_date: string
          cancelled_count: number
          cash_collected: number
          commission: number
          deleted_at: string | null
          delivery_fees: number
          discounts: number
          gross_sales: number
          net_payout: number
          orders_count: number
          updated_at: string
          vendor_id: string
          wallet_collected: number
        }
        Insert: {
          adjustments?: number
          business_date: string
          cancelled_count?: number
          cash_collected?: number
          commission?: number
          deleted_at?: string | null
          delivery_fees?: number
          discounts?: number
          gross_sales?: number
          net_payout?: number
          orders_count?: number
          updated_at?: string
          vendor_id: string
          wallet_collected?: number
        }
        Update: {
          adjustments?: number
          business_date?: string
          cancelled_count?: number
          cash_collected?: number
          commission?: number
          deleted_at?: string | null
          delivery_fees?: number
          discounts?: number
          gross_sales?: number
          net_payout?: number
          orders_count?: number
          updated_at?: string
          vendor_id?: string
          wallet_collected?: number
        }
        Relationships: [
          {
            foreignKeyName: "vendor_earnings_daily_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_holidays: {
        Row: {
          created_at: string
          deleted_at: string | null
          holiday_date: string
          id: string
          reason: string | null
          updated_at: string
          vendor_id: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          holiday_date: string
          id?: string
          reason?: string | null
          updated_at?: string
          vendor_id: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          holiday_date?: string
          id?: string
          reason?: string | null
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_holidays_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_schedules: {
        Row: {
          closes_at: string
          created_at: string
          day_of_week: number
          deleted_at: string | null
          id: string
          is_closed: boolean
          opens_at: string
          slot: number
          updated_at: string
          vendor_id: string
        }
        Insert: {
          closes_at: string
          created_at?: string
          day_of_week: number
          deleted_at?: string | null
          id?: string
          is_closed?: boolean
          opens_at: string
          slot?: number
          updated_at?: string
          vendor_id: string
        }
        Update: {
          closes_at?: string
          created_at?: string
          day_of_week?: number
          deleted_at?: string | null
          id?: string
          is_closed?: boolean
          opens_at?: string
          slot?: number
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_schedules_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_staff: {
        Row: {
          can_edit_menu: boolean
          can_manage_orders: boolean
          created_at: string
          deleted_at: string | null
          id: string
          staff_role: string
          updated_at: string
          user_id: string
          vendor_id: string
        }
        Insert: {
          can_edit_menu?: boolean
          can_manage_orders?: boolean
          created_at?: string
          deleted_at?: string | null
          id?: string
          staff_role?: string
          updated_at?: string
          user_id: string
          vendor_id: string
        }
        Update: {
          can_edit_menu?: boolean
          can_manage_orders?: boolean
          created_at?: string
          deleted_at?: string | null
          id?: string
          staff_role?: string
          updated_at?: string
          user_id?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_staff_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_staff_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      vendors: {
        Row: {
          area_id: string
          auto_open: boolean
          brand_id: string | null
          capacity_per_slot: number | null
          city_id: string
          contact_landline: string | null
          contact_phone: string | null
          created_at: string
          deleted_at: string | null
          delivery_fee_override: number | null
          delivery_radius_km: number
          description: string | null
          description_ar: string | null
          description_normalized: string | null
          geohash_prefix: string
          id: string
          is_active: boolean
          is_approved: boolean
          is_busy: boolean
          is_open: boolean
          latitude: number
          legal_name: string | null
          logo_path: string | null
          longitude: number
          menu_version: number
          minimum_order_value: number
          name: string
          name_ar: string
          name_ar_normalized: string | null
          name_normalized: string | null
          prep_time_max_minutes: number
          prep_time_minutes: number
          rating_avg: number
          rating_count: number
          reject_rate: number
          slug: string
          updated_at: string
          vertical_type: string
        }
        Insert: {
          area_id: string
          auto_open?: boolean
          brand_id?: string | null
          capacity_per_slot?: number | null
          city_id: string
          contact_landline?: string | null
          contact_phone?: string | null
          created_at?: string
          deleted_at?: string | null
          delivery_fee_override?: number | null
          delivery_radius_km?: number
          description?: string | null
          description_ar?: string | null
          description_normalized?: string | null
          geohash_prefix: string
          id?: string
          is_active?: boolean
          is_approved?: boolean
          is_busy?: boolean
          is_open?: boolean
          latitude: number
          legal_name?: string | null
          logo_path?: string | null
          longitude: number
          menu_version?: number
          minimum_order_value?: number
          name: string
          name_ar: string
          name_ar_normalized?: string | null
          name_normalized?: string | null
          prep_time_max_minutes?: number
          prep_time_minutes?: number
          rating_avg?: number
          rating_count?: number
          reject_rate?: number
          slug: string
          updated_at?: string
          vertical_type: string
        }
        Update: {
          area_id?: string
          auto_open?: boolean
          brand_id?: string | null
          capacity_per_slot?: number | null
          city_id?: string
          contact_landline?: string | null
          contact_phone?: string | null
          created_at?: string
          deleted_at?: string | null
          delivery_fee_override?: number | null
          delivery_radius_km?: number
          description?: string | null
          description_ar?: string | null
          description_normalized?: string | null
          geohash_prefix?: string
          id?: string
          is_active?: boolean
          is_approved?: boolean
          is_busy?: boolean
          is_open?: boolean
          latitude?: number
          legal_name?: string | null
          logo_path?: string | null
          longitude?: number
          menu_version?: number
          minimum_order_value?: number
          name?: string
          name_ar?: string
          name_ar_normalized?: string | null
          name_normalized?: string | null
          prep_time_max_minutes?: number
          prep_time_minutes?: number
          rating_avg?: number
          rating_count?: number
          reject_rate?: number
          slug?: string
          updated_at?: string
          vertical_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendors_area_id_fkey"
            columns: ["area_id"]
            isOneToOne: false
            referencedRelation: "areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendors_brand_id_fkey"
            columns: ["brand_id"]
            isOneToOne: false
            referencedRelation: "brands"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendors_city_id_fkey"
            columns: ["city_id"]
            isOneToOne: false
            referencedRelation: "cities"
            referencedColumns: ["id"]
          },
        ]
      }
      voucher_redemptions: {
        Row: {
          created_at: string
          discount_amount: number
          id: string
          order_id: string | null
          sub_order_id: string | null
          user_id: string
          voucher_id: string
        }
        Insert: {
          created_at?: string
          discount_amount: number
          id?: string
          order_id?: string | null
          sub_order_id?: string | null
          user_id: string
          voucher_id: string
        }
        Update: {
          created_at?: string
          discount_amount?: number
          id?: string
          order_id?: string | null
          sub_order_id?: string | null
          user_id?: string
          voucher_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "voucher_redemptions_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "voucher_redemptions_sub_order_id_fkey"
            columns: ["sub_order_id"]
            isOneToOne: false
            referencedRelation: "sub_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "voucher_redemptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "voucher_redemptions_voucher_id_fkey"
            columns: ["voucher_id"]
            isOneToOne: false
            referencedRelation: "vouchers"
            referencedColumns: ["id"]
          },
        ]
      }
      vouchers: {
        Row: {
          applies_to_vendor_ids: string[]
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          discount_type: string
          discount_value: number
          first_order_only: boolean
          id: string
          is_active: boolean
          max_discount_cap: number | null
          min_order_value: number
          name: string | null
          updated_at: string
          usage_count: number
          usage_limit_per_user: number | null
          usage_limit_total: number | null
          valid_from: string
          valid_until: string | null
          vertical_type: string | null
        }
        Insert: {
          applies_to_vendor_ids?: string[]
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          discount_type: string
          discount_value: number
          first_order_only?: boolean
          id?: string
          is_active?: boolean
          max_discount_cap?: number | null
          min_order_value?: number
          name?: string | null
          updated_at?: string
          usage_count?: number
          usage_limit_per_user?: number | null
          usage_limit_total?: number | null
          valid_from?: string
          valid_until?: string | null
          vertical_type?: string | null
        }
        Update: {
          applies_to_vendor_ids?: string[]
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          discount_type?: string
          discount_value?: number
          first_order_only?: boolean
          id?: string
          is_active?: boolean
          max_discount_cap?: number | null
          min_order_value?: number
          name?: string | null
          updated_at?: string
          usage_count?: number
          usage_limit_per_user?: number | null
          usage_limit_total?: number | null
          valid_from?: string
          valid_until?: string | null
          vertical_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vouchers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
        ]
      }
      wallets: {
        Row: {
          balance: number
          currency: string
          id: string
          owner_id: string
          owner_type: string
          status: string
          status_reason: string | null
          updated_at: string
          version: number
        }
        Insert: {
          balance?: number
          currency?: string
          id?: string
          owner_id: string
          owner_type: string
          status?: string
          status_reason?: string | null
          updated_at?: string
          version?: number
        }
        Update: {
          balance?: number
          currency?: string
          id?: string
          owner_id?: string
          owner_type?: string
          status?: string
          status_reason?: string | null
          updated_at?: string
          version?: number
        }
        Relationships: []
      }
    }
    Views: {
      riders_public: {
        Row: {
          first_name: string | null
          id: string | null
          last_name: string | null
          phone_number: string | null
          rating_avg: number | null
          rating_count: number | null
          vehicle_plate: string | null
          vehicle_type: string | null
        }
        Insert: {
          first_name?: string | null
          id?: string | null
          last_name?: string | null
          phone_number?: string | null
          rating_avg?: number | null
          rating_count?: number | null
          vehicle_plate?: string | null
          vehicle_type?: string | null
        }
        Update: {
          first_name?: string | null
          id?: string | null
          last_name?: string | null
          phone_number?: string | null
          rating_avg?: number | null
          rating_count?: number | null
          vehicle_plate?: string | null
          vehicle_type?: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      adjust_wallet_v1: {
        Args: {
          p_amount: number
          p_idempotency_key?: string
          p_owner_id: string
          p_owner_type: string
          p_reason: string
          p_reference?: string
        }
        Returns: {
          applied: boolean
          ledger_entry_id: string
          wallet_balance: number
          wallet_version: number
        }[]
      }
      admin_delete_area_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_brand_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_city_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_cuisine_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_item_option_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_menu_category_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_menu_item_size_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_menu_item_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_option_choice_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_vendor_area_v1: {
        Args: { p_area_id: string; p_reason: string; p_vendor_id: string }
        Returns: undefined
      }
      admin_delete_vendor_cuisine_v1: {
        Args: { p_cuisine_id: string; p_reason: string; p_vendor_id: string }
        Returns: undefined
      }
      admin_delete_vendor_holiday_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_vendor_schedule_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_vendor_staff_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_vendor_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_delete_voucher_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_area_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_brand_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_city_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_cuisine_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_item_option_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_menu_category_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_menu_item_size_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_menu_item_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_option_choice_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_vendor_area_v1: {
        Args: { p_area_id: string; p_reason: string; p_vendor_id: string }
        Returns: undefined
      }
      admin_restore_vendor_cuisine_v1: {
        Args: { p_cuisine_id: string; p_reason: string; p_vendor_id: string }
        Returns: undefined
      }
      admin_restore_vendor_holiday_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_vendor_schedule_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_vendor_staff_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_vendor_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_restore_voucher_v1: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      admin_upsert_area_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_brand_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_city_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_cuisine_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_item_option_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_menu_category_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_menu_item_size_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_menu_item_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_option_choice_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_rider_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_vendor_area_v1: {
        Args: { p_area_id: string; p_patch: Json; p_vendor_id: string }
        Returns: undefined
      }
      admin_upsert_vendor_cuisine_v1: {
        Args: { p_cuisine_id: string; p_patch: Json; p_vendor_id: string }
        Returns: undefined
      }
      admin_upsert_vendor_holiday_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_vendor_schedule_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_vendor_staff_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_vendor_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: string
      }
      admin_upsert_voucher_v1: {
        Args: { p_id: string; p_patch: Json }
        Returns: string
      }
      begin_collection_v1: {
        Args: {
          p_channel: string
          p_order_id: string
          p_payment_method: string
        }
        Returns: {
          already_collected: boolean
          amount_due: number
          can_collect_cash: boolean
          can_collect_wallet: boolean
          cash_held: number
          currency: string
          effective_cash_limit: number
        }[]
      }
      cancel_order_v1: {
        Args: { p_order_id: string; p_reason?: string; p_sub_order_id?: string }
        Returns: {
          cancelled_count: number
          outcome: string
          refund_amount: number
          refund_currency: string
        }[]
      }
      claim_events_v1: {
        Args: { p_limit?: number }
        Returns: {
          event_ids: number[]
          language: string
          oldest_event: string
          order_id: string
          order_number: string
          recipient: string
          recipient_id: string
          template_key: string
          variables: Json
        }[]
      }
      claim_order_v1: {
        Args: { p_assignment_id: string; p_rider_id: string }
        Returns: {
          assignment_id: string
          distance_km: number
          eta_minutes: number
          has_pay_rule: boolean
          order_id: string
          platform_revenue: number
          rider_id: string
          rider_pay_base: number
          rider_pay_bonus: number
          rider_pay_distance: number
          rider_pay_total: number
        }[]
      }
      collect_cash_v1: {
        Args: {
          p_amount: number
          p_order_id: string
          p_proof_path?: string
          p_reference?: string
        }
        Returns: {
          cash_held: number
          collected_amount: number
          currency: string
          ledger_entry_id: string
          order_id: string
          reference: string
        }[]
      }
      collect_wallet_v1: {
        Args: { p_channel: string; p_order_id: string; p_reference?: string }
        Returns: {
          cash_held: number
          channel: string
          collected_amount: number
          currency: string
          order_id: string
          platform_cash_moved: number
          reference: string
        }[]
      }
      complete_delivery_v1: {
        Args: {
          p_lat?: number
          p_lng?: number
          p_order_id: string
          p_proof_path?: string
        }
        Returns: {
          currency: string
          delivered_at: string
          order_id: string
          platform_revenue: number
          rider_gross_total: number
          rider_pay_total: number
          tips: number
          vendor_payable: number
        }[]
      }
      complete_profile_v1: {
        Args: { p_first_name: string; p_last_name: string; p_phone: string }
        Returns: {
          can_browse: boolean
          can_order: boolean
          has_address: boolean
          has_phone: boolean
          missing: string[]
          profile_completed_at: string
        }[]
      }
      delete_address_v1: { Args: { p_id: string }; Returns: boolean }
      effective_cash_limit_v1: { Args: { p_rider_id: string }; Returns: number }
      freeze_wallet_v1: {
        Args: {
          p_idempotency_key?: string
          p_owner_id: string
          p_owner_type: string
          p_reason: string
        }
        Returns: {
          frozen: boolean
          owner_id: string
          owner_type: string
          status: string
          status_reason: string
          version: number
          wallet_id: string
        }[]
      }
      get_admin_metrics_v1: {
        Args: { p_date?: string }
        Returns: {
          payload: Json
        }[]
      }
      get_available_orders_v1: {
        Args: { p_lat: number; p_lng: number; p_radius_km?: number }
        Returns: {
          area_id: string
          assignment_id: string
          currency: string
          dropoff_km: number
          est_pickup_minutes: number
          order_id: string
          order_number: string
          pickup_km: number
          placed_at: string
          total: number
          vendor_count: number
        }[]
      }
      get_commission_v1: {
        Args: { p_scope?: string; p_target_id?: string }
        Returns: {
          applies_to: string
          commission_type: string
          effective_from: string
          effective_until: string
          is_active: boolean
          is_effective_now: boolean
          max_amount: number
          min_amount: number
          rule_id: string
          scope: string
          target_id: string
          value: number
        }[]
      }
      get_fee_rules_v1: {
        Args: { p_zone_id: string }
        Returns: {
          currency: string
          delivery_base_fee: number
          free_radius_km: number
          is_active: boolean
          max_distance_km: number
          max_vendors: number
          min_order_value: number
          multiplier_bps: number
          per_km_fee: number
          service_fee_enabled: boolean
          service_fee_type: string
          service_fee_value: Json
          vendor_count: number
          zone_id: string
          zone_name: string
          zone_name_ar: string
        }[]
      }
      get_flags_v1: {
        Args: { p_app_role?: string; p_app_version?: string }
        Returns: {
          flag_key: string
          value: Json
        }[]
      }
      get_my_rider_profile_v1: {
        Args: never
        Returns: {
          cancelled_deliveries: number
          cash_held: number
          completed_deliveries: number
          country_code: string
          created_at: string
          current_latitude: number
          current_longitude: number
          effective_cash_limit: number
          first_name: string
          home_area_id: string
          is_active: boolean
          is_online: boolean
          is_verified: boolean
          last_location_at: string
          last_name: string
          phone_number: string
          rating_avg: number
          rating_count: number
          rider_id: string
          status: string
          vehicle_plate: string
          vehicle_type: string
        }[]
      }
      get_platform_float_v1: {
        Args: { p_from: string; p_to?: string }
        Returns: {
          adjustments: number
          business_date: string
          cash_expected: number
          cash_remitted: number
          commissions: number
          delivery_fees: number
          external_cash_orders: number
          external_wallet_orders: number
          rider_cuts: number
          rider_payable: number
          service_fees: number
          variance: number
          vendor_payable: number
        }[]
      }
      get_profile_status_v1: {
        Args: never
        Returns: {
          can_browse: boolean
          can_order: boolean
          has_address: boolean
          has_phone: boolean
          missing: string[]
          profile_completed_at: string
        }[]
      }
      get_rider_earnings_v1: {
        Args: { p_from?: string; p_to?: string }
        Returns: {
          payload: Json
        }[]
      }
      get_vendor_dashboard_v1: {
        Args: { p_vendor_id?: string }
        Returns: {
          payload: Json
        }[]
      }
      get_vendor_earnings_v1: {
        Args: { p_from?: string; p_to?: string }
        Returns: {
          payload: Json
        }[]
      }
      get_vendor_feed_v1: {
        Args: {
          p_area_id?: string
          p_limit?: number
          p_offset?: number
          p_open_only?: boolean
          p_query?: string
          p_sort?: string
          p_vertical?: string
        }
        Returns: {
          payload: Json
        }[]
      }
      get_wallet_balance_v1: {
        Args: { p_owner_id: string; p_owner_type: string }
        Returns: {
          balance: number
          currency: string
          drift: number
          ledger_balance: number
          owner_id: string
          recent_entries: Json
          status: string
          status_reason: string
          version: number
        }[]
      }
      haversine_km: {
        Args: { p_lat1: number; p_lat2: number; p_lng1: number; p_lng2: number }
        Returns: number
      }
      list_frozen_v1: {
        Args: never
        Returns: {
          balance: number
          currency: string
          owner_id: string
          owner_type: string
          status: string
          status_reason: string
          updated_at: string
          version: number
          wallet_id: string
        }[]
      }
      list_my_addresses_v1: {
        Args: never
        Returns: {
          apartment: string | null
          area_id: string | null
          area_name: string | null
          building: string | null
          created_at: string
          deleted_at: string | null
          delivery_instructions: string | null
          floor: string | null
          geohash: string
          geohash_prefix: string
          id: string
          is_default: boolean
          label: string
          landmark: string | null
          last_used_at: string | null
          latitude: number
          longitude: number
          updated_at: string
          user_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "addresses"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      mark_events_delivered_v1: {
        Args: { p_ids: number[]; p_result?: Json }
        Returns: {
          marked: number
          still_open: number
        }[]
      }
      normalize_text_v1:
        | { Args: { p_text: string }; Returns: string }
        | { Args: { p_value: Json }; Returns: string }
      place_order_v1: {
        Args: {
          p_idempotency_key: string
          p_payment_channel?: string
          p_payment_method: string
          p_quote_id: string
        }
        Returns: {
          order_id: string
          order_number: string
          sub_orders: Json
          totals: Json
        }[]
      }
      quote_order_v1: {
        Args: {
          p_address_id: string
          p_cart_id: string
          p_delivery_type?: string
          p_grouping?: string
          p_rider_tip?: number
          p_voucher_code?: string
        }
        Returns: {
          expires_at: string
          fee_breakdown: Json
          fingerprint: string
          limits: Json
          per_vendor: Json
          quote_id: string
          rejections: Json
          totals: Json
          warnings: Json
        }[]
      }
      reconcile_day_v1: {
        Args: { p_date: string; p_explanation?: string }
        Returns: {
          balanced: boolean
          business_date: string
          cash_expected: number
          cash_remitted: number
          external_cash_orders: number
          external_wallet_orders: number
          in_flight_payouts: number
          open_payout_net: number
          rider_payable: number
          variance: number
          vendor_payable: number
        }[]
      }
      register_device_token_v1: {
        Args: {
          p_app_role: string
          p_app_version?: string
          p_platform: string
          p_token: string
        }
        Returns: {
          app_role: string
          app_version: string | null
          created_at: string
          id: string
          language: string
          last_seen_at: string
          platform: string
          token: string
          user_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "device_tokens"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      remove_cart_item_v1: {
        Args: { p_cart_item_id: string }
        Returns: {
          cart_id: string
          remaining: number
        }[]
      }
      run_payout_v1: {
        Args: {
          p_account_id: string
          p_action?: string
          p_method?: string
          p_payout_id?: string
          p_payout_type: string
          p_period_end: string
          p_period_start: string
          p_reference?: string
        }
        Returns: {
          already_applied: boolean
          cash_amount: number
          fee_amount: number
          gross_amount: number
          line_count: number
          net_amount: number
          payout_id: string
          payout_status: string
        }[]
      }
      search_catalog_v1: {
        Args: {
          p_area_id?: string
          p_filters?: Json
          p_limit?: number
          p_query: string
        }
        Returns: {
          distance_km: number
          is_open: boolean
          item_category_id: string
          item_id: string
          item_image_path: string
          item_name: string
          item_name_ar: string
          item_price: number
          kind: string
          minimum_order_value: number
          prep_time_minutes: number
          rating_avg: number
          rating_count: number
          score: number
          vendor_id: string
          vendor_name: string
          vendor_name_ar: string
        }[]
      }
      semver_gte: { Args: { p_have: string; p_need: string }; Returns: boolean }
      set_commission_rule_v1: {
        Args: {
          p_applies_to: string
          p_commission_type?: string
          p_effective_from?: string
          p_scope: string
          p_target_id?: string
          p_value_bps: number
        }
        Returns: {
          applies_to: string
          effective_from: string
          rule_id: string
          scope: string
          superseded_id: string
          value: number
        }[]
      }
      set_default_address_v1: {
        Args: { p_id: string }
        Returns: {
          apartment: string | null
          area_id: string | null
          area_name: string | null
          building: string | null
          created_at: string
          deleted_at: string | null
          delivery_instructions: string | null
          floor: string | null
          geohash: string
          geohash_prefix: string
          id: string
          is_default: boolean
          label: string
          landmark: string | null
          last_used_at: string | null
          latitude: number
          longitude: number
          updated_at: string
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "addresses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_fee_tier_v1: {
        Args: {
          p_multiplier_bps: number
          p_vendor_count: number
          p_zone_id: string
        }
        Returns: {
          created: boolean
          multiplier_bps: number
          vendor_count: number
          zone_id: string
        }[]
      }
      transition_order_v1: {
        Args: {
          p_order_id: string
          p_reason?: string
          p_sub_order_id: string
          p_to_status: string
        }
        Returns: {
          from_status: string
          order_status: string
          sub_order_id: string
          to_status: string
        }[]
      }
      update_profile_v1: {
        Args: { p_patch: Json }
        Returns: {
          can_browse: boolean
          can_order: boolean
          has_address: boolean
          has_phone: boolean
          missing: string[]
          profile_completed_at: string
        }[]
      }
      upsert_cart_item_v1: {
        Args: {
          p_menu_item_id: string
          p_quantity?: number
          p_selected_options?: Json
          p_selected_size_id?: string
          p_special_instructions?: string
        }
        Returns: {
          cart_id: string
          cart_item_id: string
          is_new: boolean
          quantity: number
          unit_price: number
        }[]
      }
      upsert_my_address_v1: {
        Args: { p_id?: string; p_patch: Json }
        Returns: {
          apartment: string | null
          area_id: string | null
          area_name: string | null
          building: string | null
          created_at: string
          deleted_at: string | null
          delivery_instructions: string | null
          floor: string | null
          geohash: string
          geohash_prefix: string
          id: string
          is_default: boolean
          label: string
          landmark: string | null
          last_used_at: string | null
          latitude: number
          longitude: number
          updated_at: string
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "addresses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
