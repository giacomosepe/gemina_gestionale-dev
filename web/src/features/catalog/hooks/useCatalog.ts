// The catalogue's data: one query per list, and mutations that put the refreshed list the function returns straight into the cache.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { callFunction } from "../../../shared/api/client";
import type { Category, DataRequest, Direction, Milestone, ServiceField } from "../logic/types";

const call = <T,>(action: string, input: Record<string, unknown> = {}) => callFunction<T>("catalogo", action, input);

function useListMutation<L, I>(key: readonly unknown[], action: string, extra: Record<string, unknown> = {}) {
  const qc = useQueryClient();
  return useMutation({ mutationFn: (input: I) => call<L>(action, { ...extra, ...(input as Record<string, unknown>) }), onSuccess: (list) => qc.setQueryData(key, list) });
}

// ---- categories
const categoriesKey = ["catalog", "categories"] as const;
export const useCategories = () => useQuery({ queryKey: categoriesKey, queryFn: () => call<{ categories: Category[] }>("categories.list") });
export const useSaveCategory = () => useListMutation<{ categories: Category[] }, { id?: string; name?: string; active?: boolean; macro_category?: string | null; standard_terms?: string | null }>(categoriesKey, "categories.save");
export const useMoveCategory = () => useListMutation<{ categories: Category[] }, { id: string; direction: Direction }>(categoriesKey, "categories.move");
export const useDeleteCategory = () => useListMutation<{ categories: Category[] }, { id: string }>(categoriesKey, "categories.delete");

// ---- milestones
const milestonesKey = ["catalog", "milestones"] as const;
export const useMilestones = () => useQuery({ queryKey: milestonesKey, queryFn: () => call<{ milestones: Milestone[] }>("milestones.list") });
export const useSaveMilestone = () => useListMutation<{ milestones: Milestone[] }, { id?: string; name: string; days?: number | null }>(milestonesKey, "milestones.save");
export const useSetMilestoneActive = () => useListMutation<{ milestones: Milestone[] }, { id: string; active: boolean }>(milestonesKey, "milestones.setActive");
export const useMoveMilestone = () => useListMutation<{ milestones: Milestone[] }, { id: string; direction: Direction }>(milestonesKey, "milestones.move");

// ---- data requests
const dataRequestsKey = ["catalog", "dataRequests"] as const;
export const useDataRequests = () => useQuery({ queryKey: dataRequestsKey, queryFn: () => call<{ data_requests: DataRequest[] }>("dataRequests.list") });
export const useArchiveDataRequest = () => useListMutation<{ data_requests: DataRequest[] }, { id: string; archived: boolean }>(dataRequestsKey, "dataRequests.archive");
export interface DataRequestInput {
  id?: string; name: string; data_type: string; save_on_company: boolean; save_on_contact: boolean; save_on_deal: boolean; save_on_case: boolean;
  required_by_default: boolean; options?: string | null; help?: string | null;
}
export const useSaveDataRequest = () => useListMutation<{ data_requests: DataRequest[] }, DataRequestInput>(dataRequestsKey, "dataRequests.save");

// ---- fields of a category
const fieldsKey = (categoryId: string) => ["catalog", "fields", categoryId] as const;
export const useCategoryFields = (categoryId: string) => useQuery({ queryKey: fieldsKey(categoryId), queryFn: () => call<{ fields: ServiceField[] }>("fields.list", { category_id: categoryId }) });
export const useSaveField = (categoryId: string) =>
  useListMutation<{ fields: ServiceField[] }, { id?: string; label: string; field_type: string; options?: string | null; required: boolean; initial_value?: string | null; help?: string | null }>(
    fieldsKey(categoryId), "fields.save", { category_id: categoryId });
export const useSetFieldActive = (categoryId: string) => useListMutation<{ fields: ServiceField[] }, { id: string; active: boolean }>(fieldsKey(categoryId), "fields.setActive");
export const useMoveField = (categoryId: string) => useListMutation<{ fields: ServiceField[] }, { id: string; direction: Direction }>(fieldsKey(categoryId), "fields.move");
