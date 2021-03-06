
#### Load libraries ####
library(readr)
library(tidyverse) # For reading and manipulating data
library(shiny) # for making Shiny app
library(ggplot2) # for plotting data
library(leaflet) # for mapping
library(shinyjs) # for interactive clicking
library(gdata) # reorder legends
library(shinydashboard)
library(shinyWidgets)
library(shinycssloaders)
library(here) # helps us keep the files in order (www)
library(RColorBrewer) #to color the plot
library(grid) #to add annotations to the plot (using grobs)
library(cowplot)
library(plotrix)
library(forcats)

####################

### Read in data ###

####################

raw_data <- read_csv(here("www","data","ALL_raw.csv"), col_types = cols(Trt2_int = col_integer(),
                                                                    Trt1 = col_character(),
                                                                    Trt2 = col_character(),
                                                                    Trt1_int2 = col_character(),
                                                                    Trt2_int2 = col_character(),
                                                                    Trt1_details = col_character(),
                                                                    Trt2_details = col_character(),
                                                                    trt_specifics = col_character(),
                                                                    Tillage_1 = col_character(),
                                                                    Tillage_2 = col_character(),
                                                                    nutrient_groups = col_character(),
                                                                    cc_group1 = col_character(),
                                                                    cc_group2 = col_character(),
                                                                    pm_group1 = col_character(),
                                                                    pm_group2 = col_character()
                                                                      )
                     )

map.data <- read_csv(here("www","data", "mapping","site-data_with_counties.csv"))
references <- read_csv(here("www", "data", "references-for-app.csv"), col_types = cols(Paper_id = col_integer())) %>%
  #changing strings to be utf-8 encoded
  mutate(citation = iconv(citation, 'latin1', 'UTF-8', sub = ''))

#using built-in state data to add region to map.data
data(state)



################################################################

### Transform raw data to a summary we can use for the plot ###

################################################################

#base summary data. this will be transformed later to create rolling means for the soil depth
summary_base <- raw_data %>% mutate_if(is.factor,  #converts blank cells in factor cols to NAs
                                               fct_explicit_na,
                                               na_level = "NA") %>%
  # We group by all the possible variable inputs to have a consistent starting point for us to filter off of.
  group_by(Review, group_level1, group_level2, group_level3, sample_depth, sample_year, Trt_compare, Trt_1name, Trt_2name,
           #Trt1_details, Trt2_details, trt_specifics, nutrient_groups) %>%
           trt_specifics, nutrient_groups, cc_group1, cc_group2, pm_group1, pm_group2) %>%
  summarise(mean_per_change = mean(per_change, na.rm = TRUE), #means of differences of percent change ((trt-control)/control)
            sem_per_change = std.error(per_change, na.rm = TRUE), #if results in NA then that needs to go to infinity
            mean_actual_diff = mean(actual_diff, na.rm = TRUE), #mean of differences in values
            sem_actual_diff = std.error(actual_diff, na.rm = TRUE), #if results in NA then that needs to go to infinity
            num_papers = n_distinct(Paper_id), # Number of papers for each summary
            num_comparisons = length(Paper_id), #Number of comparisons for each summary
            paper_id_list = paste(unique(Paper_id), collapse = ";")) %>% #List of unique papers for each summry
  ungroup %>%
  #combining them makes sorting a bit easier (only have to do one column instead of 2)
  mutate(group_facet_level32 = paste(group_level3, group_level2, sep = "_"),
         sample_depth = ifelse(is.na(sample_depth), "Soil Surface", sample_depth)) %>%
  #get rid of rows with not enough data
  filter(num_comparisons > 4 & sem_per_change != 0 & sem_actual_diff != 0) %>%
  # We don't care about comparing a treatment to itself for the app (as long as both aren't NA)
  filter((Trt_1name != Trt_2name) | (is.na(Trt_1name) & is.na(Trt_2name)))






#' using summary_base, create new means/standard errors based on cumulative depth grouping
#' this relies on both summary_data and sample_year_ordered (both created above)
#' @param year_group should be an element of sample_year
cum_depth_avg <- function(depth_group){
  summary_base %>%
    #takes all the depth groupings before, filter only non-na sample depth
    filter(sample_depth %in% sample_depth_ordered[1:which(sample_depth_ordered == depth_group)]) %>%
    #group by everything except depth, so that we can add the cumulative part
    group_by(Review, group_level1, group_level2, group_level3, sample_year, Trt_compare, Trt_1name, Trt_2name, trt_specifics, nutrient_groups) %>%
    #create a simple mean between depths. there are more observations in the eariler groups, but we are claiming that the different grouping are still of equal importance
    mutate(mean_per_change = mean(mean_per_change),
           sem_per_change = mean(sem_per_change),
           mean_actual_diff = mean(mean_actual_diff),
           sem_actual_diff = mean(sem_actual_diff)) %>%
    filter(sample_depth == depth_group) %>%
    ungroup()
}

# This is just a list of all the possible sample depths. It's used in the function cum_depth_avg to make the mean/se cumulative.
# Soil surface should be first in the list, but str_sort puts it last. We do operations to get it in front
sample_depth_ordered <- summary_base$sample_depth %>% 
  unique %>% 
  str_sort(numeric = T) %>%
  setdiff('Soil Surface') %>%
  c('Soil Surface', .)

#this combines the result of cum_avg for ALL of the depth groups
summary_data <- purrr::map_df(sample_depth_ordered, ~cum_depth_avg(.x))

#quick check to make sure we didn't lose any rows. see debug_app.R for more extensive tests
#nrow(summary_data) == nrow(summary_base)


#statements to convert SEMs=0 to Inf (unnecessary if we have a filter statement to get rid of 0 sem/small number of comparisons)
# SEMS based on 1 value reuslt in NA <- this converts NA to Infinity to variability in the data  
summary_data$sem_per_change <- ifelse(is.na(summary_data$sem_per_change), Inf, summary_data$sem_per_change)
summary_data$sem_actual_diff <- ifelse(is.na(summary_data$sem_actual_diff), Inf, summary_data$sem_actual_diff)



# Useful if we want region data for the map

state_region_lookup <- data.frame(State = state.abb, Region = state.region) %>%
  mutate(Region = fct_recode(Region, Midwest = 'North Central'))
map.data <- map.data %>% 
  left_join(state_region_lookup, by = 'State')


#' Turn the citations into html links using the doi
#' @param citation is a string doi
#' @return HTML that makes the doi a hyperlink
citation_with_hyperlink <- function(citation){
  doi <- citation %>% 
    #get everything after 'DOI: '
    str_extract('(?<=DOI: ).*')
  #turn into html links
  doi_link <- paste0('<a target=_blank href=http://dx.doi.org/', doi, '>', citation, '</a>')
  return(doi_link)
}

#replace citations with their html links
references$citation <- citation_with_hyperlink(references$citation)


